# frozen_string_literal: true

ruby_version_path = File.join(File.expand_path(__dir__), '.ruby-version')
ruby File.read(ruby_version_path, mode: 'rb').chomp

source 'https://rubygems.org'

gem 'activerecord'
gem 'amazing_print'
gem 'diffy'
gem 'json'
gem 'nokogiri'
gem 'safe_attributes'
gem 'solid_assert'
gem 'sqlite3'

group :development do
  gem 'rubocop', require: false
  gem 'solargraph'
end
