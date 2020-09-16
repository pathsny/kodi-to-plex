require 'nokogiri'
require 'sqlite3'
require 'active_record'
require 'json'
require 'solid_assert'
SolidAssert.enable_assertions
require File.join(__dir__, 'models')

Object.send(:remove_const, :DATA_PATH) if Object.const_defined?(:DATA_PATH)
DATA_PATH = File.join(__dir__, 'data')

class Importer
  class << self
    def new(settings)
      raise "Can only create one instance" unless @instance.nil?
      @instance = super(settings)
      ActiveRecord::Base.establish_connection(
        adapter: 'sqlite3',
        database: File.join(DATA_PATH, settings[:db_name])
      )
      @instance
    end
  end

  def initialize(settings)
    @settings = settings
  end

  def get_kodi_data
    @kodi_data ||= File.open(File.join(DATA_PATH, @settings[:kodi_data])) {|f| Nokogiri::XML(f) }
  end

  def make_changed_at
    changed_at = @settings[:changed_at] || @settings[:changed_at_seed]
    @settings[:changed_at] = changed_at + @settings[:changed_at_skip]
    changed_at
  end

  def clear_tables
    MetadataItemSetting.delete_all
    MetadataItemView.delete_all
  end

  def retrieve_metadata(video_data)
    media_file = video_data[:filenameandpath].sub(
      @settings[:kodi_media_path_match],
      @settings[:plex_media_path_replace],
    )
    media_parts = MediaPart.only_one!(:file =>  media_file)
    media_item = media_parts.media_item
    media_item.metadata_item
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

    metadata_item = retrieve_metadata(video_data)

    # How we handle duplicate records
    # created_at will be for the oldest record
    # last_viewed_at and updated_at for the newest record.
    # view_count to be the sum of all the records
    # view_offset to be the value of the newest record
    setting = MetadataItemSetting.find_or_initialize_by(guid: metadata_item.guid)
    setting.attributes = {
      account_id: @settings[:account_id],
      last_viewed_at: [
        video_data[:last_played],
        setting.last_viewed_at
      ].compact.max,
      created_at: [
        video_data[:last_played],
        setting.created_at
      ].compact.min,
      updated_at: [
        video_data[:last_played],
        setting[:updated_at]
      ].compact.max,
      view_count: video_data[:play_count] + (setting.view_count || 0),
      changed_at: make_changed_at(),
    }
    setting.view_offset = (
      video_data[:position] == 0 ? nil : video_data[:position]*1000
    ) if setting.last_viewed_at_changed?
    setting.save!

    video_data[:play_count].times do |i|
      parent_id = metadata_item.parent_id
      assert parent_id.nil?, "non nil parents not handled yet for #{video_data[:filenameandpath]}"


      MetadataItemView.create!(
        account_id: @settings[:account_id],
        guid: metadata_item.guid,
        metadata_type: metadata_item.metadata_type,
        library_section_id: metadata_item.library_section_id,
        grandparent_title: '',
        parent_index: -1,
        parent_title: '',
        index: metadata_item.index,
        title: metadata_item.title,
        thumb_url: metadata_item.user_thumb_url,
        viewed_at: video_data[:last_played],
        grandparent_guid: '',
        originally_available_at: metadata_item.originally_available_at,
        device_id: @settings[:device_id],
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
