require File.join(__dir__, 'importer')

settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
settings = JSON.parse(settings_file, :symbolize_names => true)
importer = Importer.new(settings)
importer.clear_tables
importer.import_movie_nodes_from_path("//movie")
importer.close()
