# frozen_string_literal: true

require File.join(__dir__, 'importer')

settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
settings = JSON.parse(settings_file, symbolize_names: true)
importer = Importer.new(settings)
importer.clear_tables
importer.import_kodi_nodes_from_xpath('//movie', :live_action, :movie)
importer.import_kodi_nodes_from_xpath('//tvshow',:live_action, :tv)
importer.import_kodi_nodes_from_xpath('//movie', :anime, :movie)
importer.import_kodi_nodes_from_xpath("//tvshow", :anime, :tv)
failed_assertions = importer.assertions.to_a
Importer.close()
unless failed_assertions.empty?
  grouped_errors = failed_assertions.group_by do |e|
    error_line = e.backtrace.find {|l| l.match(/kodi-to-plex\/importer/) }
    error_line
  end
  ap grouped_errors
  raise 'Script ran with Errors'
end
