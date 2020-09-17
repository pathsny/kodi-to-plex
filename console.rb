load File.join(__dir__, 'importer.rb')
require File.join(DATA_PATH, 'test_imports')

def import_movies
  settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
  settings = JSON.parse(settings_file, :symbolize_names => true)
  Importer.close()
  importer = importer_with_test_inputs(settings)
  nil
end

def reload_script
  load File.join(__FILE__)
end
