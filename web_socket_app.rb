
class WebSocketApp < Rack::WebSocket::Application
  
  API_VERSION=1
  
  attr_accessor :skip, :leader, :auth
  attr_reader :addresses
  
  def ips_for(env)
    forward = env['HTTP_X_FORWARDED_FOR']
    [env['REMOTE_ADDR'], forward ? forward.split(',').last.strip : nil].compact
  end
  
  def ip_for(env)
    env['REMOTE_ADDR']
  end
  
  def forwarded_ip_for(env)
    if env['HTTP_X_FORWARDED_FOR']
      addr.split(',').last.strip
    else
      nil
    end
  end
  
  def on_open(env)
    # We cant rely on cookies so wait for the auth message
    @addresses = ips_for(env)
    log_info "OPEN"
  end
  
  def send_message(data)
    send_data data.to_json
  end
  
  def log_error(message)
    SUBSCRIPTIONS.logger.error "SOCKET[#{self.object_id},#{(@addresses||[]).join(':')}] #{message}"
  end
  
  def log_info(message)
    SUBSCRIPTIONS.logger.info "SOCKET[#{self.object_id},#{(@addresses||[]).join(':')}] #{message}"
  end
  
  def on_message(env, data)
    begin
      process_message(env, data)
    rescue Exception => e
      SUBSCRIPTIONS.logger.error "[EXCEPTION: #{e.inspect}\n#{e.backtrace.join("\n")}"
    end
  end
  
  def current_channel_id
    @current_channel_id
  end
  
  def user_id
    @current_user ? "user_#{@current_user.id}" : "anon_#{object_id}"
  end
  
  def user_name
    @current_name
  end
  
  def user_name_trip
    "#{@current_name}#{@current_tripcode}"
  end
  
  def user_data
    {:id => user_id, :name => user_name, :tripcode => @current_tripcode, :anon => @current_user ? false : true, :leader => @leader ? true : false }
  end
  
  def current_user
    @current_user
  end
  
  def scope_for(channel)
    if @scope_chan != channel
      @scope = nil
      @scope_chan = channel
    end
    
    if @scope.nil?
      if @current_user && @current_user.admin
        @scope = 'sumin'
      elsif @current_user && channel.admin_channels.include?(@current_user)
        @scope = 'admin'
      elsif channel.moderators.find_by_name("#{user_name}#{@current_tripcode}")
        @scope = 'mod'
      else
        @scope = ''
      end
    end
    @scope
  end
  
  def process_message(env, data)
    message = JSON.parse(data) rescue {}
    now = Time.now.utc
    
    log_info "MSG: #{message.inspect}"
    
    # Socket needs to be authenticated FIRST
    return if !auth && message['t'] != 'auth'
    
    case message['t']
    when 'auth'
      # Authenticate the session
      # This is so connections can be associated with names
      # Note that besides banning there isn't really much in the way of
      # user control.
      user = User.find_by_auth_token(message['auth_token'])
      ban = Ban.find_active_by_ip(@addresses)
      if ban
        # User was banned
        send_message({'t' => 'goaway', 'reason' => 'ban', 'comment' => ban.comment})
        log_info "BANNED"
      elsif user && user.auth_token?
        # Admin / channel admin login
        @current_user = user
        @current_name, @current_tripcode = Tripcode.encode(user.nick)
        send_message({'t' => 'hello', 'user' => user_data, 'api' => API_VERSION})
        @current_user.update_attribute(:auth_token, nil)
        log_info "AUTH #{user_id}"
        SUBSCRIPTIONS.register_connection(self)
        @auth = true
      else
        # Anonymous login
        @current_name, @current_tripcode = Tripcode.encode(message['name']||'Anonymous')
        unt = user_name_trip
        
        if !User.find_by_eval_nick(unt)
          send_message({'t' => 'hello', 'user' => user_data, 'api' => API_VERSION})
          log_info "AUTH #{user_id}"
          SUBSCRIPTIONS.register_connection(self)
          @auth = true
        else
          # not allowed
          send_message({'t' => 'goaway', 'reason' => 'inuse'})
          log_info "INUSE #{user_id}"
        end
      end
    when 'message'
      # Messages are broadcast to subscribers
      if SUBSCRIPTIONS.connection_in_channel_id?(self, @current_channel_id)
        SUBSCRIPTIONS.send_message(@current_channel_id, 'message', {
          'uid' => user_id,
          'content' => message['content']
        })
        
        #log_info "MSG #{@current_channel_id} <#{user_id}>#{message['content']}"
      end
    when 'usermod'
      # User wants to change their name
      new_name, new_tripcode = Tripcode.encode((message['name']||'').strip)
      if @current_user.nil? and !new_name.empty? and new_name != user_name and !User.find_by_eval_nick("#{new_name}#{new_tripcode}")
        @current_name = new_name
        @current_tripcode = new_tripcode
        SUBSCRIPTIONS.send_message(@current_channel_id, 'usermod', {'user' => user_data})
        log_info "MOD #{user_id}"
      end
    when 'subscribe'
      # Subscribe to channel
      channel = Channel.find_by_id(message['channel_id'])
      if channel
        # Unsubscribe from previous
        if @current_channel_id
          #puts "#{user_id} UNSUBSCRIBE EXISTING #{@current_channel_id}"
          SUBSCRIPTIONS.unsubscribe(self, @current_channel_id)
        end
        
        #puts "SUBSCRIBING TO CHANNEL #{channel.name} (#{channel.current_video.try(:url)})"
        if SUBSCRIPTIONS.subscribe(self, channel)
          @current_channel_id = channel.id
          log_info "SUBSCRIBED #{user_id} #{channel.id}"
          
          # Get current video
          if channel.current_video
            #puts "VIDEO? #{channel.current_video.url} #{channel.current_video.provider}"
            send_message(channel.current_video.to_info.merge({
                          't' => 'video',
                          'time' => channel.current_time,
                          'force' => true}))
          end
          
          # Get current playlist
          videos = channel.videos.order('position ASC')
          unless videos.empty?
            videos.each do |video|
              info = video.to_info.merge({'t' => 'playlist_video'})
              send_message(info)
            end
          end
        else
          send_message({'t' => 'goaway', 'reason' => 'nothere'})
        end
      else
        send_message({'t' => 'goaway', 'reason' => 'notfound'})
      end
    when 'unsubscribe'
      # Unsubscribe from channel
      channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
      SUBSCRIPTIONS.unsubscribe(self, channel) if channel
      @current_channel_id = nil
    when 'skip'
      @skip = 1
      channel = SUBSCRIPTIONS.channel_metadata(current_channel_id)
      if channel
        users = SUBSCRIPTIONS.user_count_in_channel_id(channel.id)
        skips = SUBSCRIPTIONS.skip_count_in_channel_id(channel.id)
        SUBSCRIPTIONS.send_message(current_channel_id, 'skip', {'count' => skips})
        channel.skip_video!(skips, users)
      end
    when 'unskip'
      @skip = 0
      skips = SUBSCRIPTIONS.skip_count_in_channel_id(current_channel_id)
      SUBSCRIPTIONS.send_message(current_channel_id, 'skip', {'count' => skips})
    when 'leader'
      # Choose a new leader
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if scope_for(channel) != ''
          SUBSCRIPTIONS.set_channel_leader(@current_channel_id, message['user_id'])
        end
      end
    when 'lock'
      # Lock/unlock playlist
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if scope_for(channel) != ''
          channel.update_attribute(:locked, message['locked'])
        end
      end
    when 'kick'
      # Kick a user
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if scope_for(channel) != ''
          SUBSCRIPTIONS.kick(message['user_id'])
        end
      end
    when 'ban'
      # Kick a user
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if scope_for(channel) != ''
          SUBSCRIPTIONS.ban(message['user_id'])
        end
      end
    when 'video'
      # Force the video
      # Note: Only leaders or moderators can do this.
      
      # TWO OPTIONS:
      # 1) Provide video id (in playlist)
      # 2) Provide video url (grabs metadata later)
      
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if @leader || scope_for(channel) != ''
          if message['video_id']
            video = channel.videos.find_by_id(message['video_id'])
            channel.play_item(video) if video
          elsif message['url']
            channel.quickplay_video(Video.get_playback_info(message['url']), Time.now.utc, {:added_by_ip => addresses.join(','), :added_by_user => user_name_trip})
          end
          
          log_info "VIDEO CHANGED #{user_id}"
        end
      end
    when 'sort_videos'
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if channel and (!channel.locked or scope_for(channel) != '')
          # Simple conform order to input list
          order = message['order']
          start = channel.videos.length
          channel.videos.each do |v|
            idx = order.index(v.id)
            v.position = idx||start
            start += 1 if idx.nil?
            v.save
          end
        end
      end
    when 'add_video'
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if channel and (!channel.locked or scope_for(channel) != '')
          if channel.video_limit.to_i == 0 or channel.videos.length < channel.video_limit
            video = channel.add_video(Video.get_playback_info(message['url']), {:added_by_ip => @addresses.join(','), :added_by_user => user_name_trip})
          end
        end
      end
    when 'del_video'
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if channel and scope_for(channel) != ''
          video = channel.videos.find_by_id(message['video_id'])
          if video
            if channel.current_video == video
              video.update_attributes({:playlist => false})
            else
              video.destroy
            end
          end
        end
      end
    when 'video_finished'
      # Advance to next video
      # Note: Only leaders or moderators can do this.
      
      # Only the owner of the channel can set the video
      #puts "#{user_id} VIDEO FINISHED #{@current_channel_id}"
      
      if SUBSCRIPTIONS.has_channel_id?(@current_channel_id)
        channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
        if @leader || scope_for(channel) != ''
          channel.next_video!
          log_info "VIDEO FINISHED #{user_id}"
        end
      end
    when 'video_time'
      # Set video time
      # Note: Only leaders can do this.
      
      channel = SUBSCRIPTIONS.channel_metadata(@current_channel_id)
      if channel && SUBSCRIPTIONS.has_channel_id?(channel.id)
        if !message['time'].nil? and @leader
          # Adjust channel model time if delta is too large
          current_time = channel.current_time(now)
          if (current_time - message['time'] < -1.0) or (current_time - message['time'] > 1.0)
            #puts "ADJUSTING CHANNEL TIME: #{message['time']} vs #{current_time} / #{channel.current_time(now)} #{current_time - message['time']}"
            channel.delta_start_time!(message['time'], now)
          end
        end
      end
    end
  end
  
  def on_close(env)
    log_info "CLOSE #{user_id}"
    SUBSCRIPTIONS.unsubscribe(self)
  end
end
