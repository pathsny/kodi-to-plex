# frozen_string_literal: true

load File.join(__dir__, 'importer.rb')
load File.join(__dir__, 'verifier.rb')
load File.join(__dir__, 'custom_logic', 'test_imports.rb')

begin
  load File.join(__dir__, 'custom_logic', 'importer_custom_logic.rb')
rescue LoadError
  module ImporterCustomLogic
  end
end

def get_settings
  settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
  JSON.parse(settings_file, symbolize_names: true).merge(
    suppress_errors_till_end: false,
  )
end

def make_importer
  Importer.new(get_settings())
end

def import_movies
  Importer.close()
  importer = importer_with_test_inputs(get_settings(), live_action: [:movie])
  nil
end

def import_tv
  Importer.close()
  importer = importer_with_test_inputs(get_settings(), live_action: [:tv])
  nil
end

def seen_tv
  settings = get_settings()
  @doc = File.open(File.join(DATA_PATH, settings[:kodi_data][:live_action])) { |f| Nokogiri::XML(f) }
  seen = @doc.xpath('//tvshow')
  seenh = {}
  seen.each do |s|
    eps = s.xpath('episodedetails').map do |ep|
      {
        name: "S#{ep.xpath('season/text()').text}E#{ep.xpath('episode/text()').text}",
        last_played: ep.xpath('lastplayed/text()').text,
      }
    end

    seenh[s.xpath('title/text()').text] = {
      last_played: s.xpath('lastplayed/text()').text,
      min: eps.min_by { |e| e[:last_played] },
      max: eps.max_by { |e| e[:last_played] },
    }
  end
  seenh
end

def make_verifier
  settings = get_settings()
  Verifier.close()
  Verifier.new(settings)
end

def reload_script
  Importer.close()
  load File.join(__FILE__)
end
