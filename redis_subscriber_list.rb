
# Big nasty shared subscriptions list

class RedisSubscriberList < SubscriberList
  def initialize(opts={})
    @list = {}
    @metadata = {}
    @connections = []
    @logger = Logger.new(opts[:log]||STDOUT)
  end
  
  def reset
    @list = {}
    @metadata = {}
    @connections = []
    stop_timer
  end

  def reload_channels
  end
  
  # Refresh user data (e.g. after updating a user)
  def refresh_users
    $redis.publish(APP_CONFIG['redis_channel'], {'t' => 'refresh_users'}.to_json)
  end
  
  def refresh_channels
    $redis.publish(APP_CONFIG['redis_channel'], {'t' => 'refresh_channels'}.to_json)
  end
  
  def channel_metadata(channel_id)
    @metadata[channel_id.to_i]
  end
  
  def reset_skips(channel_id)
	  $redis.publish(APP_CONFIG['redis_channel'], {'t' => 'reset_skips', 'channel_id' => channel_id}.to_json)
  end
  
  def stats_enumerate
    {
      :connections => 0,
      :channels => {}.tap {|l| l.each{|k,v| l[k] = v.length } }
    }
  end
  
  def send_message(destination, type, message)
    if destination.respond_to?(:each)
      destination.each do |channel|
        send_message(channel, type, message)
      end
    else
      channel_id = if destination.class == Channel
        destination.id
      else
        destination
      end

      # Dispatch to redis
      $redis.publish(APP_CONFIG['redis_channel'], {'t' => 'msg', 'msg_t' => type, 'data' => message, 'channel_id' => channel_id}.to_json)
    end
  end
  
  def has_channel_id?(channel)
    false
  end
  
  def connection_in_channel_id?(connection, channel)
    true#@list[channel] && @list[channel].include?(connection) ? true : false
  end
  
  def user_in_channel_id?(user, channel)
    true#@list[channel] && @list[channel].map(&:current_user).include?(user) ? true : false
  end
  
  def user_id_in_channel_id?(user_id, channel)
    false#@list[channel] && @list[channel].map(&:user_id).include?(user_id) ? true : false
  end
  
  def user_name_trip_connected?(user_trip)
    false#@connections.index{|c| c.user_name_trip == user_trip} != nil
  end
  
  def user_count_in_channel_id(channel_id)
  	$redis.get("chan:#{channel_id}:user_count").to_i
  end
  
  def skip_count_in_channel_id(channel_id)
    $redis.get("chan:#{channel_id}:skip_count").to_i
  end
  
  def kick(user_id)
  	$redis.publish(APP_CONFIG['redis_channel'], {'t' => 'kick', 'user_id' => user_id}.to_json)
  end
  
  def ban(user_id)
    $redis.publish(APP_CONFIG['redis_channel'], {'t' => 'ban', 'user_id' => user_id}.to_json)
  end
  
  def kick_ip(ip)
  	$redis.publish(APP_CONFIG['redis_channel'], {'t' => 'kick_ip', 'ip' => ip}.to_json)
  end
  
  def set_channel_leader(channel_id, leader_id)
  	$redis.publish(APP_CONFIG['redis_channel'], {'t' => 'setleader', 'channel_id' => channel_id, 'leader_id' => leader_id}.to_json)
  end
  
  def register_connection(connection)
    @connections.push(connection)
  end
  
  def subscribe(connection, channel)
  end
  
  def unsubscribe(connection, channel=nil)
  end
end
