require 'spec_helper'

describe Channel do
  before(:each) do
    Video.delete_all
    Channel.delete_all
    User.delete_all
    Timecop.return
    SUBSCRIPTIONS.reset
  end

  describe "on construction" do
    it "should send reload channels" do
      SUBSCRIPTIONS.should_receive(:reload_channels)
      @channel = Channel.create!(:name => 'v4c')
    end
  end

  describe "an instance" do
    before do
      @channel = Channel.create!(:name => 'v4c')

      @video = Video.create!(:title => BASE_VIDEO_INFO['title'],
                            :url => BASE_VIDEO_INFO['url'],
                            :duration => 60,
                            :provider => BASE_VIDEO_INFO['provider'])
    end
    
    it "should notify SUBSCRIPTIONS of changes" do
      SUBSCRIPTIONS.should_receive(:refresh_channels)
      @channel.skip_limit = 100
      @channel.save
    end

    it "should calculate the correct current_time" do
      @channel.current_time.should == 0
      @video.update_attribute(:channel_id, @channel.id)

      @channel.play_item(@video)

      Timecop.freeze(@channel.start_time + 10.seconds) { @channel.current_time.should == 10 }
      Timecop.freeze(@channel.start_time + 30.seconds) { @channel.current_time.should == 30 }
    end

    it "should update the correct delta_start_time!" do
      @channel.current_time.should == 0
      @video.update_attribute(:channel_id, @channel.id)

      @channel.play_item(@video)

      start = @channel.start_time
      Timecop.freeze(start) do
        @channel.delta_start_time!(60)
        @channel.current_time.should == 60
        @channel.delta_start_time!(60, start + 60.seconds)
        @channel.current_time.should == 0
      end
    end

    it "next_video! should advance to the next playlist item, deleting the current non-playlist video" do
      @video.update_attribute(:channel_id, @channel.id)
      @channel.play_item(@video)
      
      # Add stuff to the playlist
      @channel.add_video({:video_id => '123', :provider => 'dummy'}, :grab_metadata => false)
      @channel.add_video({:video_id => '456', :provider => 'dummy'}, :grab_metadata => false)
      
      @channel.videos(true).length.should == 3
      
      @channel.current_video.url.should == 'H0MwvOJEBOM'
      @channel.next_video!
      @channel.videos(true).length.should == 2
      @channel.current_video.url.should == '123'
      @channel.next_video!
      @channel.current_video.url.should == '456'
    end
    
    it "next_video! should not advance to the next video if there are no playlist items" do
      @video.update_attribute(:channel_id, @channel.id)
      @channel.play_item(@video)
      
      @channel.videos.length.should == 1
      
      @channel.next_video!
      @channel.current_video.url.should == 'H0MwvOJEBOM'
    end
    
    it "skip_video! should advance to the next video if the skip count exceeds the quota" do
      # Add stuff to the playlist
      @v1 = @channel.add_video({:video_id => '123', :provider => 'dummy'}, :grab_metadata => false)
      @v2 = @channel.add_video({:video_id => '456', :provider => 'dummy'}, :grab_metadata => false)
      
      @channel.update_attribute(:skip_limit, 50)
      @channel.play_item(@v1)
      
      @channel.current_video.should == @v1
      @channel.skip_video!(1, 10)
      @channel.current_video.should == @v1
      
      @channel.current_video.should == @v1
      @channel.skip_video!(6, 10)
      @channel.current_video.should == @v2
    end

    it "should play_item existing videos in the playlist, clearing the current non-playlist video" do
      # Add stuff to the playlist
      @channel.add_video({:video_id => '123', :provider => 'dummy'}, :grab_metadata => false)
      @channel.add_video({:video_id => '456', :provider => 'dummy'}, :grab_metadata => false)
      @channel.reload.videos.length.should == 2
      @channel.videos.map(&:url).should == ['123', '456']
    end

    it "add_video method should add a new video on the end of the playlist" do
      # Add stuff to the playlist
      @channel.add_video({:video_id => '123', :provider => 'dummy'}, :grab_metadata => false)
      @channel.add_video({:video_id => '456', :provider => 'dummy'}, :grab_metadata => false)
      @channel.reload.videos.length.should == 2
      @channel.videos.last.url.should == '456'
    end

    it "quickplay_video method should add and instantly play a new video, replacing non-playlist items" do
      @video.update_attribute(:channel_id, @channel.id)
      @channel.play_item(@video)
      @channel.current_video.should == @video
      
      @channel.quickplay_video({:video_id => '123', :provider => 'dummy'}, Time.now.utc, :grab_metadata => false)
      @channel.current_video.url.should == '123'
      @channel.current_video.id.should == @video.id
    end

    it "quickplay_video method should add and instantly play an new video, not replacing playlist items" do
      @video.update_attribute(:channel_id, @channel.id)
      @video.update_attribute(:playlist, true)
      @channel.play_item(@video)
      @channel.current_video.should == @video
      
      @channel.quickplay_video({:video_id => '123', :provider => 'dummy'}, Time.now.utc, :grab_metadata => false)
      @channel.current_video.url.should == '123'
      @channel.current_video.id.should_not == @video.id
    end

    it "should notify SUBSCRIPTIONS of changes to the current video and time" do
      @video.update_attribute(:channel_id, @channel.id)
      @video.update_attribute(:playlist, true)
      @channel.play_item(@video)
      
      start = @channel.start_time
      Timecop.freeze(start) do
        SUBSCRIPTIONS.should_receive(:send_message).with(@channel.id, 'video_time', {"time"=>60.0})
        @channel.delta_start_time!(60)
      end
    end
    
    it "should enumerator moderators via moderator_list" do
      Moderator.create!(:name => 'Sanic', :channel_id => @channel.id)
      Moderator.create!(:name => 'Gal', :channel_id => @channel.id)
      Moderator.create!(:name => 'Mareo', :channel_id => @channel.id)
      
      @channel.moderator_list.should == "Sanic\nGal\nMareo"
    end
    
    it "should assign moderators via moderator_list" do
      # 2 mods
      Moderator.create!(:name => 'Sanic', :channel_id => @channel.id)
      Moderator.create!(:name => 'Mareo', :channel_id => @channel.id)
      
      @channel.moderator_list.should == "Sanic\nMareo"
      
      # Remove 1, add 2
      @channel.moderator_list = "Mareo\nGal\nTorTanic"
      @channel.moderator_list.should == "Mareo\nGal\nTorTanic"
      
      # Should be consistent between instances
      @channel.save
      @channel = Channel.find_by_id(@channel.id)
      @channel.moderator_list.should == "Mareo\nGal\nTorTanic"
    end
    
    it "should notify subscriptions when any of the metadata fields have changed" do
      # ['name', 'permalink', 'banner', 'footer', 'skip_limit', 'connection_limit', 'locked', 'video_limit']
      fields_to_change = {'name' => 'New Name',
                          'permalink' => 'New Permalink',
                          'locked' => true,
                          'banner' => 'Banner',
                          'footer' => 'Footer',
                          'skip_limit' => 101,
                          'connection_limit' => 1000,
                          'video_limit' => 200}
      SUBSCRIPTIONS.should_receive(:send_message).with(@channel.id, 'chanmod', fields_to_change.merge('id' => @channel.id))
      @channel.update_attributes(fields_to_change)
    end
  end
end