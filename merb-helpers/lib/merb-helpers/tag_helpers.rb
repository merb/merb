module Merb
  module Helpers
    module Tag    
      # Creates a generic HTML tag. You can invoke it a variety of ways.
      #
      # @example
      #   tag :div
      #   # <div></div>
      #
      #   tag :div, 'content'
      #   # <div>content</div>
      #
      #   tag :div, :class => 'class'
      #   # <div class="class"></div>
      #
      #   tag :div, 'content', :class => 'class'
      #   # <div class="class">content</div>
      #
      #   tag :div do
      #     'content'
      #   end
      #   # <div>content</div>
      #
      #   tag :div, :class => 'class' do
      #     'content'
      #   end
      #   # <div class="class">content</div>
      def tag(name, contents = nil, attrs = {}, &block)
        attrs, contents = contents, nil if contents.is_a?(Hash)
        contents = capture(&block) if block_given?
        open_tag(name, attrs) + contents.to_s + close_tag(name)
      end

      # Creates the opening tag with attributes for the provided name.
      #
      # @param [#to_s] name Tag name
      # @param [Hash] attrs A hash where all members will be mapped to
      #   `key="value"`.
      #
      # @note This tag will need to be closed
      def open_tag(name, attrs = nil)
        "<#{name}#{' ' + attrs.to_html_attributes unless attrs.blank?}>"
      end

      # Creates a closing tag.
      #
      # @param [#to_s] name Tag name
      def close_tag(name)
        "</#{name}>"
      end

      # Creates a self closing tag.  Like `<br/>` or `<img src="..."/>`
      #
      # @param (see #open_tag)
      def self_closing_tag(name, attrs = nil)
        "<#{name}#{' ' + attrs.to_html_attributes if attrs && !attrs.empty?}/>"
      end
        
    end
  end
end

module Merb::GlobalHelpers
  include Merb::Helpers::Tag
end    
