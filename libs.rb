require 'nokogiri'
require 'sqlite3'
require 'active_record'
require 'json'
require 'solid_assert'
SolidAssert.enable_assertions
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

    def clear_tables
      MetadataItemSetting.delete_all
      MetadataItemView.delete_all
    end

    def import_video(video_data)
      invariant "last played and play stats must be consistent #{video_data[:filenameandpath]}" do
        if video_data[:last_played].nil?
          video_data[:play_count] == 0 && video_data[:position] == 0
        else
          video_data[:play_count] != 0 || video_data[:position] != 0
        end
      end
      return if video_data[:last_played].nil?

      media_file = video_data[:filenameandpath].sub(
        SETTINGS[:kodi_media_path_match],
        SETTINGS[:plex_media_path_replace],
      )
      media_parts = MediaPart.only_one!(:file =>  media_file)
      media_item = media_parts.media_item
      metadata_item = media_item.metadata_item

      last_viewed_at = video_data[:last_played].strftime("%Y-%m-%d %H:%M:%S")
      MetadataItemSetting.create(
        account_id: SETTINGS[:account_id],
        guid: metadata_item.guid,
        view_count: video_data[:play_count],
        view_offset: video_data[:position] == 0 ? nil : video_data[:position]*1000,
        last_viewed_at: last_viewed_at,
        created_at: last_viewed_at,
        updated_at: last_viewed_at,
        changed_at: make_changed_at()
      )

      video_data[:play_count].times do |i|
        parent_id = metadata_item.parent_id
        assert parent_id.nil?, "non nil parents not handled yet for #{video_data[:filenameandpath]}"


        MetadataItemView.create(
          account_id: SETTINGS[:account_id],
          guid: metadata_item.guid,
          metadata_type: metadata_item.metadata_type,
          library_section_id: metadata_item.library_section_id,
          grandparent_title: '',
          parent_index: -1,
          parent_title: '',
          index: metadata_item.index,
          title: metadata_item.title,
          thumb_url: metadata_item.user_thumb_url,
          viewed_at: last_viewed_at,
          grandparent_guid: '',
          originally_available_at: metadata_item.originally_available_at,
          device_id: SETTINGS[:device_id],
        )
      end
    end

    def get_imdb_id(node)
      unique_ids = node.xpath('./uniqueid[@type="imdb"]')
      return unique_ids.first if unique_ids.children.count == 1
      ids = node.xpath('./id')
      assert ids.children.count == 1, "found duplicate id node #{ids.text}"
      id = ids.first.text
      return id if id.match(/tt\d{7}/)
      assert false, "could not find imdb id #{ids.text}"
    end

    def import_movie_node(node)
      last_played = DateTime.parse(node.xpath('./lastplayed/text()').text) rescue nil
      import_video(
        position: node.xpath('./resume/position/text()').text.to_i,
        play_count: node.xpath('./playcount/text()').text.to_i,
        last_played: last_played,
        filenameandpath: node.xpath('./filenameandpath/text()').text,
        imdb: get_imdb_id(node),
      )
    end

    def import_move_node_from_path(path)
      import_movie_node(get_kodi_data().xpath(path).first)
    end
  end
end
