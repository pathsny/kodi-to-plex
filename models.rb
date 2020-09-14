require 'safe_attributes/base'
require 'solid_assert'


module ActiveRecordOnlyOne
  extend ActiveSupport::Concern

  module ClassMethods
    def only_one!(options)
      list = where(options)
      assert list.size == 1
      list.first
    end
  end
end

ActiveRecord::Base.send(:include, ActiveRecordOnlyOne)

class MediaPart < ActiveRecord::Base
  belongs_to :media_item

  include SafeAttributes::Base
  bad_attribute_names :hash


end

class MediaItem < ActiveRecord::Base
  has_many :media_parts
  belongs_to :metadata_item
end

class MetadataItem < ActiveRecord::Base
  has_many :media_items

  include SafeAttributes::Base
  bad_attribute_names :hash
end

class MetadataItemView < ActiveRecord::Base
end

class MetadataItemSetting < ActiveRecord::Base
end
