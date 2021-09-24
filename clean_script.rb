require 'fileutils'

def data_file(name)
  File.join(__dir__, 'data', name)
end

def clear_data(name)
  FileUtils.rm(data_file(name))
rescue Errno::ENOENT
end

def copydata(clean_name, working_name)
  FileUtils.cp(data_file(clean_name), data_file(working_name))
rescue Errno::ENOENT
end

clear_data("com.plexapp.plugins.library.db")
clear_data("com.plexapp.plugins.library.db-wal")
clear_data("com.plexapp.plugins.library.db-shm")

FileUtils.cp(data_file("livedb.db"), data_file("com.plexapp.plugins.library.db"))
copydata("livedb.db-wal", "com.plexapp.plugins.library.db-wal")
copydata("livedb.db-shm", "com.plexapp.plugins.library.db-shm")
load(File.join(__dir__, 'script.rb'))
