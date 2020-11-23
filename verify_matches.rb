# frozen_string_literal: true

require 'optparse'
require File.join(__dir__, 'importer')

settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
Settings = JSON.parse(settings_file, symbolize_names: true)
importer = Importer.instance || Importer.new(Settings)

def verify_all()
  folders = Settings[:folders_to_verify_matches].flat_map { |path| Dir[path] }.sort
  ap "I found #{folders.count} folders"
  errors = []
  folders.each do |f|
    verify_folder(f)
  rescue StandardError => e
    errors.push({
      file: f,
      error: e,
    })
  end
  ap errors
end
ANIDB_MATCH_REGEX = %r{com.plexapp.agents.hama://anidb-(?<anidb>\d*)(?:/(?<season>.*)/(?<episode>.*))?\?lang=en}.freeze

def metadata(f)
  m = MetadataItem.joins(media_items: [:media_parts]).where(
    media_items: { media_parts: { file: f } },
  ).first
  m.guid.match(ANIDB_MATCH_REGEX)&.named_captures&.dig('anidb')
end

def verify_folder(f)
  match_data = File.read("#{f}/anidb.id").match(/^(\d+)\s*$/)
  raise "did not match for #{f}" unless match_data

  anidb_id_from_id_file = match_data[1]
  selected_file = sample_file(f)
  anidb_id_from_metadata = metadata(selected_file)
  if anidb_id_from_metadata != anidb_id_from_id_file
    raise "ids dont match for #{f}. metadata id is #{anidb_id_from_metadata} and anidb_id id is #{anidb_id_from_id_file}. sample file was #{selected_file}"
  end
end

ACCEPTED_EXTENSIONS = %w[.avi .mpg .mkv .ogm .mp4 .flv .wmv].freeze

def sample_file(folder)
  candidate_files = Dir["#{folder}/*"].select do |f|
    ACCEPTED_EXTENSIONS.include?(File.extname(f))
  end
  assert(!candidate_files.empty?, "could not find a valid candidate for #{folder}")
  candidate_files.sample
end
