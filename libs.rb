require 'nokogiri'
require 'sqlite3'
require 'active_record'
require 'json'
require File.join(__dir__, 'models')

Object.send(:remove_const, :DATA_PATH) if Object.const_defined?(:DATA_PATH)
DATA_PATH = File.join(__dir__, 'data')

settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
Object.send(:remove_const, :SETTINGS) if Object.const_defined?(:SETTINGS)
SETTINGS = JSON.parse(settings_file, :symbolize_names => true)

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: File.join(DATA_PATH, SETTINGS[:db_name])
)


class Importer
  class << self
    def get_kodi_data
      @kodi_data ||= File.open(File.join(DATA_PATH, SETTINGS[:kodi_data])) {|f| Nokogiri::XML(f) }
    end

    def make_changed_at
      changed_at = SETTINGS[:changed_at] || SETTINGS[:changed_at_seed]
      SETTINGS[:changed_at] = changed_at + SETTINGS[:changed_at_skip]
      changed_at
    end

    def import_video(video_data)
      last_viewed_at = video_data[:last_played].strftime("%Y-%m-%d %H:%M:%S")
      MetadataItemSettings.create(
        account_id: SETTINGS[:account_id],
        guid: video_data[:guid],
        view_count: video_data[:play_count],
        view_offset: video_data[:position] == 0 ? nil : video_data[:position]*1000,
        last_viewed_at: last_viewed_at,
        created_at: last_viewed_at,
        updated_at: last_viewed_at,
        changed_at: make_changed_at()
      )
    end

    def import_movie_node(node, guid)
      unique_ids = node.xpath('./uniqueid[@type="imdb"]')
      raise "this is unexpected #{unique_ids.inspect}" if unique_ids.children.count != 1
      import_video(
        guid: guid,
        position: node.xpath('./resume/position/text()').text.to_i,
        play_count: node.xpath('./playcount/text()').text.to_i,
        last_played: DateTime.parse(node.xpath('./lastplayed/text()').text),
        filenameandpath: node.xpath('./filenameandpath/text()').text,
        imdb: unique_ids.text,
      )
    end

    def import_move_node_from_path(path, guid)
      import_movie_node(get_kodi_data().xpath(path).first, guid)
    end
  end
end
