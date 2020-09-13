require 'nokogiri'
require 'sqlite3'
require 'active_record'
require 'json'
require File.join(__dir__, 'models')

data_path = File.join(__dir__, 'data')

settings_file = File.read(File.join(data_path, 'settings.json'))
SETTINGS = JSON.parse(settings_file, :symbolize_names => true)

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: File.join(data_path, SETTINGS[:db_name])
)


def make_changed_at
  changed_at = SETTINGS[:changed_at] || SETTINGS[:changed_at_seed]
  SETTINGS[:changed_at] = changed_at + SETTINGS[:changed_at_skip]
  changed_at
end

def import_video(video_data)
  settings_metadata = video_data.merge(
  )
  puts "going to insert #{settings_metadata.inspect}"
  MetadataItemSettings.create(
    account_id: SETTINGS[:account_id],
    guid: video_data[:guid],
    view_count: video_data[:view_count],
    view_offset: video_data[:position]*1000,
    last_viewed_at: video_data[:last_viewed_at],
    created_at: video_data[:last_viewed_at],
    updated_at: video_data[:last_viewed_at],
    changed_at: make_changed_at()
  )
end
