require 'nokogiri'
require 'sqlite3'
require 'active_record'
require 'json'
require 'solid_assert'
SolidAssert.enable_assertions
require File.join(__dir__, 'models')

begin
  require 'amazing_print'
rescue LoadError
end

Object.send(:remove_const, :DATA_PATH) if Object.const_defined?(:DATA_PATH)
DATA_PATH = File.join(__dir__, 'data')
Object.send(:remove_const, :FILE_MATCH_REGEX) if Object.const_defined?(:FILE_MATCH_REGEX)
FILE_MATCH_REGEX = /smb:\/\/.+?(?=\s,\ssmb:\/\/|$)/
Object.send(:remove_const, :IMDB_MATCH_REGEX) if Object.const_defined?(:IMDB_MATCH_REGEX)
IMDB_MATCH_REGEX = /com.plexapp.agents.imdb:\/\/(?<imdb>.*)\?lang=en/
Object.send(:remove_const, :TVEP_MATCH_REGEX) if Object.const_defined?(:TVEP_MATCH_REGEX)
TVEP_MATCH_REGEX = /com.plexapp.agents.thetvdb:\/\/(?<tvdb>\d*)\/(?<season>.*)\/(?<episode>.*)\?lang=en/

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

    def close
      if @instance
        ActiveRecord::Base.connection.close
        @instance = nil
      end
    end

    attr_reader :instance
  end

  def initialize(settings)
    @settings = settings
    @exclusions = JSON.parse(File.read(File.join(DATA_PATH, 'exclusions.json')))
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

  def retrieve_metadata(video_data, type)
    assert [:movie, :tv].include?(type), "unknown #{type} when retrieving metadata for #{video_data[:filenameandpath]}"
    media_items = video_data[:filenameandpath_split].map do |name|
      media_file = @exclusions['filename_substitutions'].fetch(name, name).sub(
        @settings[:kodi_media_path_match],
        @settings[:plex_media_path_replace],
      )
      MediaPart.only_one!(:file =>  media_file).media_item
    end.uniq
    assert media_items.size == 1, "found #{media_items.size} items for #{video_data[:filenameandpath]}"

    media_items.first.metadata_item.tap do |m|
      # Let's make sure the metadata matches before we return it.
      case type
        when :movie
          unless @exclusions['known_imdb_mismatches'].include?(m.title)
            imdb_id = m.guid.match(IMDB_MATCH_REGEX)&.named_captures&.dig('imdb')
            assert imdb_id == video_data[:imdb], "Imdb does not match for #{m.title}. Plex has #{imdb_id} and Kodi has #{video_data[:imdb]}"
          end
        when :tv
          match_data = m.guid.match(TVEP_MATCH_REGEX)&.named_captures.symbolize_keys
          assert video_data[:tvdb] == match_data[:tvdb], "TVDB ID for #{video_data[:filenameandpath]} is #{video_data[:tvdb]} in kodi and #{match_data[:tvdb]} in plex"
          assert video_data[:season] == match_data[:season], "Season for #{video_data[:filenameandpath]} is #{video_data[:season]} in kodi and #{match_data[:season]} in plex"
          assert video_data[:episode] == match_data[:episode], "Episode for #{video_data[:filenameandpath]} is #{video_data[:episode]} in kodi and #{match_data[:episode]} in plex"
      end
    end
  end

  def import_video(video_data, type)
    assert [:movie, :tv].include?(type), "unknown #{type} when importing video for #{video_data[:filenameandpath]}"
    if video_data[:last_played].nil?
      assert(
        video_data[:play_count] == 0 && video_data[:position] == 0,
        "#{video_data[:filenameandpath]} has play stats without last played",
      )
    else
      assert(
        video_data[:play_count] != 0 ||
        video_data[:position] != 0 ||
        @exclusions["allowed_missing_playstats"].include?(video_data[:filenameandpath]),
        "#{video_data[:filenameandpath]} has no play stats even with last played",
      )
    end
    return if @exclusions["filenames_to_skip"].include?(video_data[:filenameandpath])
    return if @exclusions["filename_extensions_to_skip"].include?(File.extname(video_data[:filenameandpath]))
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
        setting.last_viewed_at
      ].compact.max,
      created_at: [
        video_data[:last_played],
        setting.created_at
      ].compact.min,
      updated_at: [
        video_data[:last_played],
        setting.updated_at,
      ].compact.max,
      view_count: video_data[:play_count] + (setting.view_count || 0),
      changed_at: make_changed_at(),
    }
    setting.view_offset = (
      video_data[:position] == 0 ? nil : video_data[:position]*1000
    ) if setting.last_viewed_at_changed?
    setting.save!

    parent = metadata_item.parent_id.nil? ? nil : MetadataItem.find(metadata_item.parent_id)
    grandparent = parent&.parent_id.nil? ? nil : MetadataItem.find(parent.parent_id)

    case type
    when :movie
      assert(parent.nil? && grandparent.nil?, "Movies are expected to have nil parent. But not #{video_data[:filenameandpath]}")
    when :tv
      assert(!(parent.nil? || grandparent.nil?), "TV Episodes must have a parent and grandparent, but not #{video_data[:filenameandpath]}")
    end

    if parent
      parent_setting = MetadataItemSetting.find_or_initialize_by(guid: parent.guid)
      parent_setting.attributes = {
        account_id: @settings[:account_id],
        last_viewed_at: [
          video_data[:last_played],
          parent_setting.last_viewed_at
        ].compact.max,
        created_at: [
          video_data[:last_played],
          parent_setting.created_at
        ].compact.min,
        updated_at: [
          video_data[:last_played],
          parent_setting.updated_at,
        ].compact.max,
        view_count: (video_data[:play_count] > 0 || (parent_setting.view_count&.> 0) ? 1 : 0),
        changed_at: make_changed_at(),
      }
      parent_setting.save!
    end

    if grandparent
      grandparent_setting = MetadataItemSetting.find_or_initialize_by(guid: grandparent.guid)
      grandparent_setting.attributes = {
        account_id: @settings[:account_id],
        last_viewed_at: [
          video_data[:last_played],
          grandparent_setting.last_viewed_at
        ].compact.max,
        created_at: [
          video_data[:last_played],
          grandparent_setting.created_at
        ].compact.min,
        updated_at: [
          video_data[:last_played],
          grandparent_setting.updated_at,
        ].compact.max,
        view_count: (video_data[:play_count] > 0 || (grandparent_setting.view_count &.> 0) ? 1 : 0),
        changed_at: make_changed_at(),
      }
      grandparent_setting.save!
    end

    return if video_data[:play_count] == 0

    video_data[:play_count].times do |i|

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
    video_data[:episodes].each do |e|
      import_video(e, :tv)
    rescue StandardError => error
      ap "was processing #{e[:filenameandpath]}"
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
    episodes = node.xpath('episodedetails').map {|n| extract_kodi_ep_info(n, tvdb_id)}
    info = {
      tvdb: tvdb_id,
      **extract_base_video_info(node),
      episodes: episodes,
    }
    return if @exclusions["tv_shows_to_skip"].include?(info[:title])
    import_tv_videos(info)
  end

  def extract_kodi_ep_info(node, tvdb_id)
    {
      season: node.xpath('season').text,
      episode: node.xpath('episode').text,
      tvdb: tvdb_id,
      **extract_base_video_info(node),
      **extract_position(node),
    }
  end

  def extract_base_video_info(node)
    filenameandpath = node.xpath('./filenameandpath/text()').text
    return {
      filenameandpath: filenameandpath,
      filenameandpath_split: filenameandpath.scan(FILE_MATCH_REGEX),
      last_played: (DateTime.parse(node.xpath('lastplayed/text()').text) rescue nil),
      play_count: @exclusions["play_count_overrides"].fetch(
        filenameandpath,
        node.xpath('./playcount/text()').text.to_i,
      ),
      title: node.xpath('title').text,
    }
  end

  def extract_position(node)
    {position: node.xpath('./resume/position/text()').text.to_i}
  end

  def extract_imdb_id(node)
    unique_ids = node.xpath('./uniqueid[@type="imdb"]')
    return unique_ids.first.text if unique_ids.children.count == 1
    tmdb_ids = node.xpath('./uniqueid[@type="tmdb"]')
    if tmdb_ids.children.count == 1
      tmdb_id = tmdb_ids.first.text
      maybe_imdb_id = @exclusions["tmdb_to_imdb"][tmdb_id.to_s]
      assert maybe_imdb_id, "tmdb id #{tmdb_id} for #{node.xpath('title').text} has no imdb mapping"
      return maybe_imdb_id
    end
    ids = node.xpath('./id')
    assert ids.children.count <= 1, "found duplicate id node #{ids.text}"
    assert ids.children.count >0, "missing id node for #{node.xpath('title').text}"
    id = ids.first.text
    return id.match(/tt\d{7}/) ? id : nil
  end

  def import_movie_nodes_from_path(path)
    get_kodi_data().xpath(path).map {|n|import_movie_node(n) }
  end

  def import_tv_nodes_from_path(path)
    get_kodi_data().xpath(path).map {|n| import_tv_node(n)}
  end

  def inspect
    "#<#{self.class}:#{object_id}>"
  end

  attr_reader :settings, :exclusions
end
