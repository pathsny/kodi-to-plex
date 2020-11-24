# frozen_string_literal: true

require File.join(__dir__, 'importer')

settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
settings = JSON.parse(settings_file, symbolize_names: true)
importer = Importer.new(settings)
importer.clear_tables
importer.import_kodi_nodes_from_xpath('//movie', :live_action, :movie)
importer.import_kodi_nodes_from_xpath('//tvshow',:live_action, :tv)
failed_assertions = importer.assertions
Importer.close()
unless failed_assertions.empty?
  ap failed_assertions
  raise 'Script ran with Errors'
end
