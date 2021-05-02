# frozen_string_literal: true

require 'amazing_print'

afiles = Dir['/Volumes/default/Anime/files/**']
ap (afiles.map do |f|
  [f, Dir["#{f}/**"].select {|f| f.match(/\[\(XS?-[^\)]+\)\]/) } ]
end.select {|f, files| !(files.empty?) }.to_a)
