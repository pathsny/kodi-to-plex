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
  load File.join(__dir__, 'custom_logic', 'importer_custom_logic.rb')
rescue LoadError
  module ImporterCustomLogic
  end
end

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
Object.send(:remove_const, :ANIDB_MATCH_REGEX) if Object.const_defined?(:ANIDB_MATCH_REGEX)
ANIDB_MATCH_REGEX = %r{com.plexapp.agents.hama://anidb-(?<anidb>\d*)(?:/(?<season>.*)/(?<episode>.*))?\?lang=en}.freeze

class Importer
  prepend ImporterCustomLogic

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
    @kodi_data = {}
  end

  def get_kodi_data(kodi_data_type)
    @kodi_data[kodi_data_type] ||= File.open(File.join(DATA_PATH, @settings[:kodi_data][kodi_data_type])) { |f| Nokogiri::XML(f) }
  end

  def clear_tables
    MetadataItemSetting.delete_all
    MetadataItemView.delete_all
  end

  def media_parts_for_file_query(video_data, kodi_data_type, type)
    video_data[:filenameandpath_split].map do |name|
      substituted_name = @exclusions['filename_substitutions'].reduce(name) do |new_name, (pattern, repl)|
        new_name.sub(pattern, repl)
      end
      file_in_plex = substituted_name.sub(
        @settings[:kodi_media_path_match],
        @settings[:plex_media_path_replace],
      )
      custom_replacement_function(video_data, file_in_plex, kodi_data_type, type)
    end
  end

  def metadata_items_for_file_query(video_data, kodi_data_type, type)
    media_files = media_parts_for_file_query(video_data, kodi_data_type, type)
    metadata_items = MetadataItem.joins(media_items: [:media_parts]).where(
      media_items: { media_parts: { file: media_files } },
    ).distinct
  end

  def custom_replacement_function(video_data, file_in_plex, kodi_data_type, type)
    file_in_plex
  end

  def retrieve_movie_metadata(video_data, metadata_items)
    assert metadata_items.size == 1, "found #{metadata_items.size} items for #{video_data[:filenameandpath]}"
    metadata_items.first.tap do |metadata_item|
      unless @exclusions['known_imdb_mismatches'].include?(metadata_item.title)

        imdb_id = metadata_item.guid.match(IMDB_MATCH_REGEX)&.named_captures&.dig('imdb')
        assert_video_data(
          imdb_id == video_data[:imdb],
          video_data,
          "Imdb does not match for #{metadata_item.title}. Plex has #{imdb_id} and Kodi has #{video_data[:imdb]}",
        )
      end
    end
  end

  def retrieve_anime_movie_metadata(video_data, metadata_items)
    assert(metadata_items.size == 1, "found #{metadata_items.size} items with ids #{metadata_items.map(&:id).join(',')} for #{video_data[:filenameandpath]}")
    metadata_items.first.tap do |metadata_item|
      plex_anidb_id = metadata_item.guid.match(ANIDB_MATCH_REGEX)&.named_captures&.dig('anidb')
      expected_anidb_id = video_data[:anidb]
      assert_video_data(
        plex_anidb_id == expected_anidb_id,
        video_data,
        "Anidb does not match for #{metadata_item.title}. Plex has #{plex_anidb_id} and Kodi has #{expected_anidb_id}",
      )
      assert_video_data([0, 1].include?(metadata_item.parent.index) , video_data, "movies should only have one season. Found #{metadata_item.parent.index} unlike metadata #{metadata_item.id} with parent #{metadata_item.parent.id}")
    end
  end

  ANIME_SPECIAL_REGEX = /- episode (?<special_prefix>[SCTPO])(?<special_number>\d+)/
  ANIDB_HAMA_SPECIAL_OFFSETS = {
    S: [0],
    C: [100, 150],
    T: [200],
    P: [300],
    O: [400],
  }

  def assert_media_parts_exist(video_data, kodi_data_type, type)
    media_parts = media_parts_for_file_query(video_data, kodi_data_type, type)
    media_parts_query = MediaPart.where(file: media_parts_for_file_query(video_data, kodi_data_type, type))
    assert(media_parts_query.size == 1, "Could not find media #{media_parts} while processing #{video_data[:filenameandpath]}")
  end

  def retrieve_tv_metadata(video_data, kodi_data_type, metadata_items_query)
    metadata_items = metadata_items_query.includes(:parent)
    anime_special_match = ANIME_SPECIAL_REGEX.match(video_data[:filenameandpath])
    anime_special = kodi_data_type == :anime && anime_special_match
    if anime_special
      assert(metadata_items.size == 1, "only handle single episode specials for now while handling #{video_data[:filenameandpath]} and seeing #{metadata_items.to_a}")
      m = metadata_items.first
      assert(m.parent.index.zero?, "specials in plex should be season 0 and not #{m.parent.index} for #{video_data[:filenameandpath]}")
      special_offset = ANIDB_HAMA_SPECIAL_OFFSETS[anime_special_match[:special_prefix].to_sym]
      assert(
        special_offset.map {|o| o + anime_special_match[:special_number].to_i}.any? {|ep_number| ep_number == m.index},
        "expected index to have offset #{special_offset} and number #{anime_special_match[:special_number]} and not #{m.index} for #{video_data[:filenameandpath]}"
      )
    end
    metadata_items_for_episode = metadata_items.filter do |m|
      anime_special || ( # kodi matches were not accurate for specials
        m.index == video_data[:episode] &&
        m.parent.index == video_data[:season]
      )
    end
    if (metadata_items_for_episode.empty?)
      # lets check if the files are missing before reporting a metadata error
      assert_media_parts_exist(video_data, kodi_data_type, :tv)
    end
    assert(
      metadata_items_for_episode.size == 1,
      "found #{metadata_items_for_episode.size} items with ids #{metadata_items_for_episode.map(&:id).join(',')} for #{video_data[:filenameandpath]} season: #{video_data[:season]}, episode: #{video_data[:episode]}",
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
      regex =
        case kodi_data_type
        when :live_action
          TVEP_MATCH_REGEX
        when :anime
          ANIDB_MATCH_REGEX
        else
          assert(false, "unknown kodi_data_type #{kodi_data_type} when processing #{video_data[:filenameandpath]}")
        end
      match_data = metadata_item.guid.match(regex)&.named_captures&.symbolize_keys
      assert(
        match_data,
        "guid #{metadata_item.guid} for #{video_data[:filenameandpath]} does not match the pattern to extract show id",
      )
      case kodi_data_type
      when :live_action
        assert(
          video_data[:tvdb] == match_data[:tvdb],
          "TVDB ID for #{video_data[:filenameandpath]} is #{video_data[:tvdb]} in kodi and #{match_data[:tvdb]} in plex",
        ) unless @exclusions['known_tvdb_mismatches'].include?(metadata_item.parent.parent.title)
      when :anime
        assert(
          video_data[:anidb] == match_data[:anidb],
          "AniDB ID for #{video_data[:filenameandpath]} is #{video_data[:anidb]} in kodi and #{match_data[:anidb]} in plex",
        )
      end
      unless (kodi_data_type == :anime && match_data[:season] == '0')
        # anime specials are not correctly tagged in kodi
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
  end

  def retrieve_metadata(video_data, kodi_data_type, type)
    metadata_items_query = metadata_items_for_file_query(video_data, kodi_data_type, type)
    case [kodi_data_type, type]
    when [:live_action, :movie]
      retrieve_movie_metadata(video_data, metadata_items_query)
    when [:anime, :movie]
      retrieve_anime_movie_metadata(video_data, metadata_items_query)
    when [:live_action, :tv]
      retrieve_tv_metadata(video_data, :live_action, metadata_items_query)
    when [:anime, :tv]
      retrieve_tv_metadata(video_data, :anime, metadata_items_query)
    else
      assert(false, "unknown media type #{type} and kodi data type #{kodi_data_type} combination when retrieving metadata for #{video_data[:filenameandpath]}")
    end
  end

  def should_exclude_video_data_for_attribute(video_data, attr_name, attr_value)
    (video_data[attr_name.to_sym] == attr_value)
  end

  def should_exclude_video_data?(video_data)
    return true if @exclusions['video_data_to_skip'].any? do |vd_to_skip_attrs|
      vd_to_skip_attrs.all? { |k, v| should_exclude_video_data_for_attribute(video_data, k, v) }
    end

    filename_regexes = @exclusions['filename_regex_to_skip'].map { |r_string| Regexp.new(Regexp.escape(r_string)) }
    return true if filename_regexes.any? { |rgx| rgx.match(video_data[:filenameandpath]) }

    false
  end

  def import_video(video_data, kodi_data_type, type)
    assert([:movie, :tv].include?(type), "unknown media type #{type} when importing video for #{video_data[:filenameandpath]}")
    assert([:live_action, :anime].include?(kodi_data_type), "unknown kodi data type #{kodi_data_type} when importing video for #{video_data[:filenameandpath]}")
    if video_data[:last_played].nil?
      assert(
        (video_data[:play_count]).zero? && (video_data[:position]).zero?,
        "#{video_data[:filenameandpath]} has play stats without last played",
      )
    end

    return if should_exclude_video_data?(video_data)

    metadata_item = retrieve_metadata(video_data, kodi_data_type, type)

    # no point adding metadata since it was clearly never watched. No other metadata is interesting.
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

    case [kodi_data_type, type]
    when [:live_action, :movie]
      assert(parent.nil? && grandparent.nil?,
             "Live Action Movies are expected to have nil parent. But not #{video_data[:filenameandpath]}",)
    when [:anime, :movie], [:live_action, :tv], [:anime, :tv]
      assert(!(parent.nil? || grandparent.nil?),
             "TV Episodes or Anime must have a parent and grandparent, but not #{video_data[:filenameandpath]}",)
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

  def import_tv_videos(video_data, kodi_data_type)
    video_data[:episodes].each do |episode|
      import_video(episode, kodi_data_type, :tv)
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
    import_video(info, :live_action, :movie)
  end

  def import_anime_movie_node(node)
    info = {
      anidb: extract_anidb_id(node),
      **extract_position(node),
      **extract_base_video_info(node),
    }
    import_video(anime_info_with_anidb_corrections(info, :movie), :anime, :movie)
  end

  def import_tv_node(node)
    tvdb_id = node.xpath('uniqueid[@default]/text()').text
    episodes = node.xpath('episodedetails').map { |n| extract_kodi_ep_info(n, tvdb: tvdb_id) }
    info = {
      tvdb: tvdb_id,
      **extract_base_video_info(node),
      episodes: episodes,
    }
    return if @exclusions['tv_shows_to_skip'].include?(info[:title])

    import_tv_videos(info, :live_action)
  end

  def import_anime_tv_node(node)
    info = anime_tv_data_to_import(node)
    return if @exclusions['tv_shows_to_skip'].include?(info[:title])
    import_tv_videos(info, :anime)
  end

  def anime_tv_data_to_import(node)
    info = anime_info_with_anidb_corrections(
      {
        anidb: extract_anidb_id(node),
        **extract_base_video_info(node),
      },
      :tv,
    );
    episodes = node.xpath('episodedetails').map { |n| extract_kodi_ep_info(n, anidb: info[:anidb]) }
    {
      **info,
      episodes: episodes,
    }
  end

  def anime_info_with_anidb_corrections(info, type)

    case type
    when :movie
      info[:anidb] = @exclusions['anidb_corrections'].fetch(info[:filenameandpath], info[:anidb])
    when :tv
      info[:anidb] = @exclusions['anidb_corrections'].fetch(info[:title], info[:anidb])
    else
      assert(false, "type was called with a value thats not :movie or :tv for #{info}")
    end
    info
  end

  def import_kodi_node(node, kodi_data_type, type)
    assert [:movie, :tv].include?(type), "unknown type of media in kodi library #{type}"
    assert [:live_action, :anime].include?(kodi_data_type), "unknown kodi data type #{kodi_data_type}"
    case [type, kodi_data_type]
    when [:movie, :live_action]
      import_movie_node(node)
    when [:movie, :anime]
      import_anime_movie_node(node)
    when [:tv, :live_action]
      import_tv_node(node)
    when [:tv, :anime]
      import_anime_tv_node(node)
    end
  end

  def extract_kodi_ep_info(node, id_data)
    {
      season: node.xpath('season').text.to_i,
      episode: node.xpath('episode').text.to_i,
      **extract_base_video_info(node),
      **extract_position(node),
    }.merge(id_data)
  end

  def extract_base_video_info(node)
    filenameandpath = node.xpath('./filenameandpath/text()').text
    {
      filenameandpath: filenameandpath,
      filenameandpath_split: filenameandpath.scan(FILE_MATCH_REGEX),
      extension: File.extname(filenameandpath),
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

  def extract_anidb_id(node)
    ids = node.xpath('./id')
    assert ids.children.count <= 1, "found duplicate id node #{ids.text}"
    assert ids.children.count.positive?, "missing id node for #{node.xpath('title').text}"
    id = ids.first.text
    assert id.match(/\d+/), "invalid anidb id #{id} for #{node.xpath('title').text}"
    id
  end

  def import_kodi_nodes_from_xpath(path, kodi_data_type, type)
    get_kodi_data(kodi_data_type).xpath(path).map do |n|
      import_kodi_node(n, kodi_data_type, type)
    rescue SolidAssert::AssertionFailedError => e
      raise unless @settings[:suppress_errors_till_end]

      @assertions << e
    end
  end

  def assert_video_data(condition, video_data, message)
    assert(condition, "#{message} for #{video_data[:filenameandpath]}")
  end

  def inspect
    "#<#{self.class}:#{object_id}>"
  end

  attr_reader :settings, :exclusions, :assertions
end
