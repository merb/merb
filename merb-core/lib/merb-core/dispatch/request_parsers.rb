# encoding: UTF-8

require 'cgi'

module Merb
  module Parse

    NAME_REGEX         = /Content-Disposition:.* name="?([^\";]*)"?/ni.freeze
    CONTENT_TYPE_REGEX = /Content-Type: (.*)\r\n/ni.freeze
    FILENAME_REGEX     = /Content-Disposition:.* filename="?([^\";]*)"?/ni.freeze
    CRLF               = "\r\n".freeze
    EOL                = CRLF

    # "atom" (RFC 822).
    # Printable 7-bit clean characters with some exceptions.
    P_ATOM             = '[^\\x00-\\x20\\x22\\x28\\x29\\x2c\\x2e\\x3a-\\x3c' +
                         '\\x3e\\x40\\x5b-\\x5d\\x7f-\\xff]+'.freeze

    # "token" (RFC 2616).
    # Almost like "atom", but for HTTP and with a different set of
    # forbidden characters.
    #
    # @todo Write me
    P_TOKEN            = '[^\\x00-\\x20]+'.freeze #TODO

    # Parameter separator (RCF 822).
    # Semicolon with optional surrounding space.
    PARAM_SEP_REGEX    = /\A\s*(?:;\s*)?/

    P_QTEXT            = '[^\\x0d\\x22\\x5c\\x80-\\xff]'
    P_QUOTED_PAIR      = '\\x5c[\\x00-\\x7f]'

    # Parameter (RFC 822).
    PARAM_REGEX        = /\A(#{P_ATOM})=(?:(#{P_ATOM})|\x22((?:#{P_QTEXT}|#{P_QUOTED_PAIR})*)\x22)\x20*/n.freeze

    # Encoded header (RFC 2047).
    ENCHEADER_REGEX    = /\A=\?(#{P_ATOM})\?(#{P_ATOM})\?([^\x00-\x20\x3f\x7f-\xff]*)\?=\Z/n.freeze

    # Parameter continuation numbering (RFC 2184)
    PARAMCONT_REGEX    = /(.+)\*(\d+)\Z/.freeze

    # @param [IO] request The raw request.
    # @param [String] boundary The boundary string.
    # @param [Fixnum] content_length The length of the content.
    #
    # @raise [ControllerExceptions::MultiPartParseError] Failed to parse
    #   request.
    #
    # @return [Hash] The parsed request.
    #
    # @api plugin
    def self.multipart(request, boundary, content_length)
      boundary = "--#{boundary}"
      paramhsh = {}
      buf      = ""
      input    = request
      input.binmode if defined? input.binmode
      boundary_size = boundary.size + EOL.size
      bufsize       = 16384
      content_length -= boundary_size
      key_memo = []
      # status is boundary delimi.ter line
      status = input.read(boundary_size)
      return {} if status == nil || status.empty?
      raise ControllerExceptions::MultiPartParseError, "bad content body:\n'#{status}' should == '#{boundary + EOL}'"  unless status == boundary + EOL

      rx = /(?:#{EOL})?#{Regexp.quote(boundary)}(#{EOL}|--)/n
      loop {
        head      = nil
        body      = ''
        filename  = content_type = name = nil
        read_size = 0
        until head && buf =~ rx
          i = buf.index("\r\n\r\n")
          if( i == nil && read_size == 0 && content_length == 0 )
            content_length = -1
            break
          end
          if !head && i
            head = buf.slice!(0, i+2) # First \r\n
            buf.slice!(0, 2)          # Second \r\n

            # String#[] with 2nd arg here is returning
            # a group from match data
            filename     = head[FILENAME_REGEX, 1]
            content_type = head[CONTENT_TYPE_REGEX, 1]
            name         = head[NAME_REGEX, 1]

            if filename && !filename.empty?
              filename = decode_header_text(filename)
              body = Tempfile.new('Merb')
              body.binmode if defined? body.binmode
            end

            name = decode_header_text(name) if (name && !name.empty?)
            next
          end

          # Save the read body part.
          if head && (boundary_size+4 < buf.size)
            body << buf.slice!(0, buf.size - (boundary_size+4))
          end

          read_size = bufsize < content_length ? bufsize : content_length
          if( read_size > 0 )
            c = input.read(read_size)
            raise ControllerExceptions::MultiPartParseError, "bad content body"  if c.nil? || c.empty?
            buf << c
            content_length -= c.size
          end
        end

        # Save the rest.
        if i = buf.index(rx)
          # correct value of i for some edge cases
          if (i > 2) && (j = buf.index(rx, i-2)) && (j < i)
             i = j
           end
          body << buf.slice!(0, i)
          buf.slice!(0, boundary_size+2)

          content_length = -1  if $1 == "--"
        end

        if filename && !filename.empty?
          body.rewind
          data = {
            :filename => File.basename(filename),
            :content_type => content_type,
            :tempfile => body,
            :size => File.size(body.path)
          }
        else
          data = body
        end

        unless key_memo.include?(name) && name !~ /\[\]/ 
          paramhsh = normalize_params(paramhsh,name,data) 
        end

        # Prevent from double processing files but process other params
        key_memo << name if filename && !filename.empty?

        break  if buf.empty? || content_length == -1
      }

      paramhsh
    end

    # @param [String] query_string The query string.
    # @param [String] delimiter The query string divider.
    # @param [Boolean] preserve_order Preserve order of args.
    #
    # @return [Mash] The parsed query string (ActiveSupport::Dictionary if
    #   `preserve_order` is set).
    #
    # @example
    #   Merb::Parse.query("bar=nik&post[body]=heya")
    #     # => { :bar => "nik", :post => { :body => "heya" } }
    #
    # @api plugin
    def self.query(query_string, delimiter = '&;', preserve_order = false)
      query = preserve_order ? ActiveSupport::OrderedHash.new : {}
      for pair in (query_string || '').split(/[#{delimiter}] */n)
        key, value = unescape(pair).split('=',2)
        next if key.nil?
        if key.include?('[')
          normalize_params(query, key, value)
        else
          query[key] = value
        end
      end
      preserve_order ? query : query.with_indifferent_access
    end

    # @param [Array, Hash, ActiveSupport::OrderedHash #to_s] value The value for the
    #   query string. If this is a string, the `prefix` will be used as
    #   the key.
    # @param [#to_s] prefix The prefix to add to the query string keys.
    #
    # @return [String] The query string.
    #
    # @example
    #   params_to_query_string(10, "page")
    #     # => "page=10"
    #   params_to_query_string({ :page => 10, :word => "ruby" })
    #     # => "page=10&word=ruby"
    #   params_to_query_string({ :page => 10, :word => "ruby" }, "search")
    #     # => "search[page]=10&search[word]=ruby"
    #   params_to_query_string([ "ice-cream", "cake" ], "shopping_list")
    #     # => "shopping_list[]=ice-cream&shopping_list[]=cake"
    #
    # @api plugin
    def self.params_to_query_string(value, prefix = nil)
      case value
      when Array
        value.map { |v|
          params_to_query_string(v, "#{prefix}[]")
        } * "&"
      when Hash, ActiveSupport::OrderedHash
        value.map { |k, v|
          params_to_query_string(v, prefix ? "#{prefix}[#{escape(k)}]" : escape(k))
        } * "&"
      else
        "#{prefix}=#{escape(value)}"
      end
    end

    # @param [String] s String to URL escape.
    # @note The implementation accepts `#to_s` duck type parameters.
    #
    # @return [String] The URL-escaped string.
    #
    # @api public
    def self.escape(s)
      s.to_s.gsub(/([^ a-zA-Z0-9_.-]+)/n) {
        '%'+$1.unpack('H2'*$1.size).join('%').upcase
      }.tr(' ', '+')
    end

    # @param [String] s String to URL unescape.
    # @param [String] encoding Encoding which we force to return. Only for
    #   Ruby 1.9. If encoding is not passed it defaults to
    #   Encoding.default_internal. When this is nil (default) no encoding
    #   forcing is done.
    #
    # @return [String] The URL-unescaped string.
    #
    # @api public
    def self.unescape(s, encoding = nil)
      s = s.tr('+', ' ').gsub(/((?:%[0-9a-fA-F]{2})+)/n){
        [$1.delete('%')].pack('H*')
      }
      if s.respond_to?(:force_encoding)
        encoding ||= Encoding.default_internal
        s.force_encoding(encoding) if encoding
      end
      s
    end

    # @param [String] s String to XML escape.
    #
    # @return [String] The escaped string.
    #
    # @api public
    def self.escape_xml(s)
      Erubis::XmlHelper.escape_xml(s)
    end

    private

    # Converts a query string snippet to a hash and adds it to existing
    # parameters.
    #
    # @note On encoding-aware Ruby VMs, this assumes that either
    #   `Encoding.default_internal` is set or that query parameters are
    #   UTF-8.
    #
    # @param [Hash] parms Parameters to add the normalized parameters to.
    # @param [String] name The key of the parameter to normalize.
    # @param [String] val The value of the parameter.
    #
    # @return [Hash] Normalized parameters.
    #
    # @api private
    def self.normalize_params(parms, name, val=nil)
      name =~ %r([\[\]]*([^\[\]]+)\]*)
      key = $1 || ''
      after = $' || ''

      if val.respond_to?(:force_encoding)
        val.force_encoding(Encoding.default_internal || 'utf-8')
      end

      if after == ""
        parms[key] = val
      elsif after == "[]"
        (parms[key] ||= []) << val
      elsif after =~ %r(^\[\]\[([^\[\]]+)\]$)
        child_key = $1
        parms[key] ||= []
        if parms[key].last.is_a?(Hash) && !parms[key].last.key?(child_key)
          parms[key].last.update(child_key => val)
        else
          parms[key] << { child_key => val }
        end
      else
        parms[key] ||= {}
        parms[key] = normalize_params(parms[key], after, val)
      end
      parms
    end

  end
end

require Pathname.new(File.dirname(__FILE__)).join('request_parsers', 'header')
