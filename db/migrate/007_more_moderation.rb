class MoreModeration < ActiveRecord::Migration
  def self.up
    add_column :bans, :banned_by, :string
    add_column :bans, :banned_by_ip, :string
    
    add_column :channels, :banner, :text
    add_column :channels, :footer, :text
    
    add_column :users, :nick, :string
    add_column :users, :super_admin, :bool, :default => false
    
    add_index :users, :nick
    
    create_table :moderators do |t|
      t.integer :channel_id
      t.string  :name
      t.timestamps
    end
    
    add_index :moderators, :channel_id
    
    create_table :channel_admins, :id => false do |t|
      t.integer :channel_id
      t.integer :user_id
    end
  end

  def self.down
    remove_column :bans, :banned_by
    remove_column :bans, :banned_by_ip
    
    remove_column :channels, :banner
    remove_column :channels, :footer
    
    remove_column :users, :nick
    remove_column :users, :super_admin
    
    drop_table :channel_admins
    drop_table :moderators
  end
end
