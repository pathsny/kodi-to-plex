# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'diffy'
require File.join(__dir__, 'importer')
require File.join(DATA_PATH, 'test_imports')

settings_file = File.read(File.join(DATA_PATH, 'settings.json'))
settings = JSON.parse(settings_file, symbolize_names: true)

ref_db_path = File.join(DATA_PATH, 'test_db.db')
output_db_path = File.join(DATA_PATH, 'test_output_db.db')

FileUtils.rm_f(output_db_path)
FileUtils.rm_f(output_db_path + '-shm')
FileUtils.rm_f(output_db_path + '-wal')
FileUtils.cp(ref_db_path, output_db_path)
settings[:db_name] = 'test_output_db.db'
settings[:suppress_errors_till_end] = false
importer_with_test_inputs(settings)
Importer.close()

stdout, stderr, status = Open3.capture3('sqldiff', ref_db_path, output_db_path)
if status.success?
  expected = File.read(File.join(DATA_PATH, 'db_diff.sql'))
  diff = Diffy::Diff.new(expected, stdout).to_s(:color)
  if diff.strip.empty?
    puts "\e[32m" + 'ALL GOOD' + "\e[0m"
  else
    puts diff
  end
else
  puts "diff failed\n"
  puts stdout
  puts stderr
end
