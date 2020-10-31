# frozen_string_literal: true

require 'nokogiri'
require 'sqlite3'
require 'active_record'
require 'json'
require 'solid_assert'

SolidAssert.enable_assertions
require File.join(__dir__, 'changed_at')
require File.join(__dir__, 'models')

begin
  require 'amazing_print'
rescue LoadError
end

Object.send(:remove_const, :DATA_PATH) if Object.const_defined?(:DATA_PATH)
DATA_PATH = File.join(__dir__, 'data')
Object.send(:remove_const, :FILE_MATCH_REGEX) if Object.const_defined?(:FILE_MATCH_REGEX)
FILE_MATCH_REGEX = %r{smb://.+?(?=\s,\ssmb://|$)}.freeze
Object.send(:remove_const, :IMDB_MATCH_REGEX) if Object.const_defined?(:IMDB_MATCH_REGEX)
IMDB_MATCH_REGEX = %r{com.plexapp.agents.imdb://(?<imdb>.*)\?lang=en}.freeze
Object.send(:remove_const, :TVEP_MATCH_REGEX) if Object.const_defined?(:TVEP_MATCH_REGEX)
TVEP_MATCH_REGEX = %r{com.plexapp.agents.thetvdb://(?<tvdb>\d*)/(?<season>.*)/(?<episode>.*)\?lang=en}.freeze

class Importer
  class << self
    def new(settings)
      raise 'Can only create one instance' unless @instance.nil?

      @instance = super(settings)
      ActiveRecord::Base.establish_connection(
        adapter: 'sqlite3',
        database: File.join(DATA_PATH, settings[:db_name]),
      )
      @instance
    end

    def close
      return unless @instance

      ActiveRecord::Base.connection.close
      @instance = nil
    end

    attr_reader :instance
  end

  def initialize(settings)
    @settings = settings
    ChangedAt.init(settings)
    @exclusions = JSON.parse(File.read(File.join(DATA_PATH, 'exclusions.json')))
    @assertions = []
    @multi_ep_files = {}
  end

  def get_kodi_data
    @kodi_data ||= File.open(File.join(DATA_PATH, @settings[:kodi_data])) { |f| Nokogiri::XML(f) }
  end

  def clear_tables
    MetadataItemSetting.delete_all
    MetadataItemView.delete_all
  end

  def metadata_items_for_file_query(video_data)
    media_files = video_data[:filenameandpath_split].map do |name|
      @exclusions['filename_substitutions'].fetch(name, name).sub(
        @settings[:kodi_media_path_match],
        @settings[:plex_media_path_replace],
      )
    end
    metadata_items = MetadataItem.joins(media_items: [:media_parts]).where(
      media_items: { media_parts: { file: media_files } },
    ).distinct
  end

  def retrieve_movie_metadata(video_data)
    metadata_items = metadata_items_for_file_query(video_data)
    assert metadata_items.size == 1, "found #{metadata_items.size} items for #{video_data[:filenameandpath]}"
    metadata_items.first.tap do |metadata_item|
      unless @exclusions['known_imdb_mismatches'].include?(metadata_item.title)

        imdb_id = metadata_item.guid.match(IMDB_MATCH_REGEX)&.named_captures&.dig('imdb')
        assert(
          imdb_id == video_data[:imdb],
          "Imdb does not match for #{metadata_item.title}. Plex has #{imdb_id} and Kodi has #{video_data[:imdb]}",
        )
      end
    end
  end

  def retrieve_tv_metadata(video_data)
    metadata_items = metadata_items_for_file_query(video_data).includes(:parent)
    metadata_items_for_episode = metadata_items.filter do |m|
      m.index == video_data[:episode] &&
        m.parent.index == video_data[:season]
    end
    assert(
      metadata_items_for_episode.size == 1,
      "found #{metadata_items_for_episode.size} items for #{video_data[:filenameandpath]}",
    )

    if metadata_items.size > 1 # This is a multi-episode file. Let's make sure they're consistent
      if @multi_ep_files.key?(video_data[:filenameandpath])
        previous = @multi_ep_files[video_data[:filenameandpath]]
        assert(
          video_data[:play_count] == previous[:play_count],
          "Inconsistent play count for multiepfile #{video_data[:filenameandpath]}. Current metadata has #{video_data[:play_count]} but was #{previous[:play_count]}",
        )
        assert(
          video_data[:position] == previous[:position],
          "Inconsistent play count for multiepfile #{video_data[:filenameandpath]}. Current metadata has #{video_data[:position]} but was #{previous[:position]}",
        )
        assert(
          video_data[:last_played] == previous[:last_played],
          "Inconsistent play count for multiepfile #{video_data[:filenameandpath]}. Current metadata has #{video_data[:last_played]} but was #{previous[:last_played]}",
        )
      else
        @multi_ep_files[video_data[:filenameandpath]] = video_data
      end
    end

    metadata_items_for_episode.first.tap do |metadata_item|
      match_data = metadata_item.guid.match(TVEP_MATCH_REGEX)&.named_captures&.symbolize_keys
      assert(
        match_data,
        "guid #{metadata_item.guid} for #{video_data[:filenameandpath]} does not match the pattern to extract tvdb id",
      )
      assert(
        video_data[:tvdb] == match_data[:tvdb],
        "TVDB ID for #{video_data[:filenameandpath]} is #{video_data[:tvdb]} in kodi and #{match_data[:tvdb]} in plex",
      ) unless @exclusions['known_tvdb_mismatches'].include?(metadata_item.parent.parent.title)
      assert(
        video_data[:season] == match_data[:season].to_i,
        "GUID Mismatch: Season for #{video_data[:filenameandpath]} is #{video_data[:season]} in kodi and #{match_data[:season]} in plex. #{metadata_item.guid}",
      )
      assert(
        video_data[:episode] == match_data[:episode].to_i,
        "GUID Mismatch: Episode for #{video_data[:filenameandpath]} is #{video_data[:episode]} in kodi and #{match_data[:episode]} in plex. #{metadata_item.guid}",
      )
    end
  end

  def retrieve_metadata(video_data, type)
    case type
    when :movie
      retrieve_movie_metadata(video_data)
    when :tv
      retrieve_tv_metadata(video_data)
    else
      assert true, "unknown #{type} when retrieving metadata for #{video_data[:filenameandpath]}"
    end
  end

  def import_video(video_data, type)
    assert([:movie, :tv].include?(type), "unknown #{type} when importing video for #{video_data[:filenameandpath]}")
    if video_data[:last_played].nil?
      assert(
        (video_data[:play_count]).zero? && (video_data[:position]).zero?,
        "#{video_data[:filenameandpath]} has play stats without last played",
      )
    end
    return if @exclusions['filenames_to_skip'].include?(video_data[:filenameandpath])
    return if @exclusions['filename_extensions_to_skip'].include?(File.extname(video_data[:filenameandpath]))

    metadata_item = retrieve_metadata(video_data, type)
    return if video_data[:last_played].nil?

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
        setting.last_viewed_at,
      ].compact.max,
      created_at: [
        video_data[:last_played],
        setting.created_at,
      ].compact.min,
      updated_at: [
        video_data[:last_played],
        setting.updated_at,
      ].compact.max,
      view_count: video_data[:play_count] + (setting.view_count || 0),
    }
    if setting.last_viewed_at_changed?
      setting.view_offset = (
        (video_data[:position]).zero? ? nil : video_data[:position] * 1000
      )
    end
    setting.save! if setting.changed?

    parent = metadata_item.parent
    grandparent = parent&.parent

    case type
    when :movie
      assert(parent.nil? && grandparent.nil?,
             "Movies are expected to have nil parent. But not #{video_data[:filenameandpath]}",)
    when :tv
      assert(!(parent.nil? || grandparent.nil?),
             "TV Episodes must have a parent and grandparent, but not #{video_data[:filenameandpath]}",)
    end

    if parent
      parent_setting = MetadataItemSetting.find_or_initialize_by(guid: parent.guid)
      parent_setting.attributes = {
        account_id: @settings[:account_id],
        last_viewed_at: [
          video_data[:last_played],
          parent_setting.last_viewed_at,
        ].compact.max,
        created_at: [
          video_data[:last_played],
          parent_setting.created_at,
        ].compact.min,
        updated_at: [
          video_data[:last_played],
          parent_setting.updated_at,
        ].compact.max,
        view_count: ((video_data[:play_count]).positive? || (parent_setting.view_count&.> 0) ? 1 : 0),
      }
      parent_setting.save! if parent_setting.changed?
    end

    if grandparent
      grandparent_setting = MetadataItemSetting.find_or_initialize_by(guid: grandparent.guid)
      grandparent_setting.attributes = {
        account_id: @settings[:account_id],
        last_viewed_at: [
          video_data[:last_played],
          grandparent_setting.last_viewed_at,
        ].compact.max,
        created_at: [
          video_data[:last_played],
          grandparent_setting.created_at,
        ].compact.min,
        updated_at: [
          video_data[:last_played],
          grandparent_setting.updated_at,
        ].compact.max,
        view_count: ((video_data[:play_count]).positive? || (grandparent_setting.view_count &.> 0) ? 1 : 0),
      }
      grandparent_setting.save! if grandparent_setting.changed?
    end

    return if (video_data[:play_count]).zero?

    video_data[:play_count].times do |_i|
      MetadataItemView.create!(
        account_id: @settings[:account_id],
        guid: metadata_item.guid,
        metadata_type: metadata_item.metadata_type,
        library_section_id: metadata_item.library_section_id,
        grandparent_title: grandparent&.title || '',
        parent_index: parent&.index || -1,
        parent_title: parent&.title || '',
        index: metadata_item.index,
        title: metadata_item.title,
        thumb_url: metadata_item.user_thumb_url,
        viewed_at: video_data[:last_played],
        grandparent_guid: grandparent&.guid || '',
        originally_available_at: metadata_item.originally_available_at,
        device_id: @settings[:device_id],
      )
    end
  end

  def import_tv_videos(video_data)
    video_data[:episodes].each do |episode|
      import_video(episode, :tv)
    rescue StandardError => e
      raise
    end
  end

  def import_movie_node(node)
    info = {
      imdb: extract_imdb_id(node),
      **extract_position(node),
      **extract_base_video_info(node),
    }
    import_video(info, :movie)
  end

  def import_tv_node(node)
    tvdb_id = node.xpath('uniqueid[@default]/text()').text
    episodes = node.xpath('episodedetails').map { |n| extract_kodi_ep_info(n, tvdb_id) }
    info = {
      tvdb: tvdb_id,
      **extract_base_video_info(node),
      episodes: episodes,
    }
    return if @exclusions['tv_shows_to_skip'].include?(info[:title])

    import_tv_videos(info)
  end

  def import_kodi_node(node, type)
    assert [:movie, :tv].include?(type), "unknown #{type}"
    case type
    when :movie
      import_movie_node(node)
    when :tv
      import_tv_node(node)
    end
  end

  def extract_kodi_ep_info(node, tvdb_id)
    {
      season: node.xpath('season').text.to_i,
      episode: node.xpath('episode').text.to_i,
      tvdb: tvdb_id,
      **extract_base_video_info(node),
      **extract_position(node),
    }
  end

  def extract_base_video_info(node)
    filenameandpath = node.xpath('./filenameandpath/text()').text
    {
      filenameandpath: filenameandpath,
      filenameandpath_split: filenameandpath.scan(FILE_MATCH_REGEX),
      last_played: (DateTime.parse(node.xpath('lastplayed/text()').text) rescue nil),
      play_count: @exclusions['play_count_overrides'].fetch(
        filenameandpath,
        node.xpath('./playcount/text()').text.to_i,
      ),
      title: node.xpath('title').text,
    }
  end

  def extract_position(node)
    { position: node.xpath('./resume/position/text()').text.to_i }
  end

  def extract_imdb_id(node)
    unique_ids = node.xpath('./uniqueid[@type="imdb"]')
    return unique_ids.first.text if unique_ids.children.count == 1

    tmdb_ids = node.xpath('./uniqueid[@type="tmdb"]')
    if tmdb_ids.children.count == 1
      tmdb_id = tmdb_ids.first.text
      maybe_imdb_id = @exclusions['tmdb_to_imdb'][tmdb_id.to_s]
      assert maybe_imdb_id, "tmdb id #{tmdb_id} for #{node.xpath('title').text} has no imdb mapping"
      return maybe_imdb_id
    end
    ids = node.xpath('./id')
    assert ids.children.count <= 1, "found duplicate id node #{ids.text}"
    assert ids.children.count.positive?, "missing id node for #{node.xpath('title').text}"
    id = ids.first.text
    id.match(/tt\d{7}/) ? id : nil
  end

  def import_kodi_nodes_from_xpath(path, type)
    get_kodi_data().xpath(path).map do |n|
      import_kodi_node(n, type)
    rescue SolidAssert::AssertionFailedError => e
      raise unless @settings[:suppress_errors_till_end]

      @assertions << e
    end
  end

  def inspect
    "#<#{self.class}:#{object_id}>"
  end

  attr_reader :settings, :exclusions, :assertions
end
