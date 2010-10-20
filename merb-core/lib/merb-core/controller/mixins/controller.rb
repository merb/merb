module Merb
  # Module that is mixed in to all implemented controllers.
  module ControllerMixin

    # Queue a block to run in a background thread outside of the request
    # response dispatch.
    #
    # @param &blk proc to run later
    #
    # @example
    #     run_later do
    #       SomeBackgroundTask.run
    #     end
    #
    # @api public
    def run_later(&blk)
      Merb.run_later(&blk)
    end
    
    # Renders the block given as a parameter using chunked encoding.
    # 
    # @param &blk A block that, when called, will use send_chunks to send
    #   chunks of data down to the server. The chunking will terminate once
    #   the block returns.
    #
    # @example
    #     def stream
    #       prefix = '<p>'
    #       suffix = "</p>\r\n"
    #       render_chunked do
    #         IO.popen("cat /tmp/test.log") do |io|
    #           done = false
    #           until done
    #             sleep 0.3
    #             line = io.gets.chomp
    #
    #             if line == 'EOF'
    #               done = true
    #             else
    #               send_chunk(prefix + line + suffix)
    #             end
    #           end
    #         end
    #       end
    #     end
    #
    # @api public
    def render_chunked(&blk)
      must_support_streaming!
      headers['Transfer-Encoding'] = 'chunked'
      Proc.new { |response|
        @response = response
        response.send_status_no_connection_close('')
        response.send_header
        blk.call
        response.write("0\r\n\r\n")
      }
    end
    
    # Writes a chunk from {#render_chunked} to the response that is sent back to
    # the client. This should only be called within a `render_chunked` block.
    #
    # @param [String] data A chunk of data to return.
    #
    # @api public
    def send_chunk(data)
      only_runs_on_mongrel!
      @response.write('%x' % data.size + "\r\n")
      @response.write(data + "\r\n")
    end
    
    # @param &blk A proc that should get called outside the mutex, and
    #   which will return the value to render.
    #
    # @return [Proc] A block that the server can call later, allowing
    #   Merb to release the thread lock and render another request.
    # 
    # @api public
    def render_deferred(&blk)
      Proc.new do |response|
        response.write(blk.call)
      end
    end
    
    # Renders the passed in string, then calls the block outside the mutex
    # and after the string has been returned to the client.
    #
    # @param [String] str A string to return to the client.
    # @param &blk A block that should get called once the string has been
    #   returned.
    #
    # @return [Proc] A block that Mongrel can call after returning the
    #   string to the user.
    #
    # @api public
    def render_then_call(str, &blk)
      Proc.new do |response|
        response.write(str)
        blk.call
      end
    end

    # @param [String] url URL to redirect to. It can be either a relative
    #   or fully-qualified URL.
    # @param [Hash] opts An options hash
    # @option opts [Hash] :message (nil)
    #   Messages to pass in url query string as value for "_message"
    # @option opts [Boolean] :permanent (false)
    #   When true, return status 301 Moved Permanently
    # @option opts [String] :notice
    #   Shorthand for common usage `:message => {:notice => "..."}`
    # @option opts [String] :error
    #   Shorthand for common usage `:message => {:error => "..."}`
    # @option opts [String] :success
    #   Shorthand for common usage `:message => {:success => "..."}`
    # @option opts [String, Symbol] :status
    #   Status code to set for the response. Can be any valid redirect
    #   status. Has precedence over the :permanent parameter, which is
    #   retained for convenience.
    #
    # @return [String] Explanation of redirect.
    #
    # @example
    #     redirect("/posts/34")
    #     redirect("/posts/34", :message => { :notice => 'Post updated successfully!' })
    #     redirect("http://www.merbivore.com/")
    #     redirect("http://www.merbivore.com/", :permanent => true)
    #     redirect("/posts/34", :notice => 'Post updated successfully!')
    #
    # @api public
    def redirect(url, opts = {})
      default_redirect_options = { :message => nil, :permanent => false }
      opts = default_redirect_options.merge(opts)

      url = handle_redirect_messages(url,opts)

      _status   = opts[:status] if opts[:status]
      _status ||= opts[:permanent] ? 301 : 302
      self.status = _status

      Merb.logger.info("Redirecting to: #{url} (#{self.status})")
      headers['Location'] = url
      "<html><body>You are being <a href=\"#{url}\">redirected</a>.</body></html>"
    end

    # Retreives the redirect message either locally or from the request.
    #
    # @api public
    def message
      @_message = defined?(@_message) ? @_message : request.message
    end

    # Sends a file over HTTP.  When given a path to a file, it will set the
    # right headers so that the static file is served directly.
    #
    # @param [String] file Path to file to send to the client.
    # @param [Hash] opts Options for sending the file.
    # @option opts [String] :disposition ("attachment")
    #   The disposition of the file send.
    # @option opts [String] :filename (File.basename(file))
    #   The name to use for the file.
    # @option opts [String] :type
    #   The content type.
    #
    # @return [IO] An I/O stream for the file.
    # @todo Docs, correctness: is the return type correct?
    #
    # @api public
    def send_file(file, opts={})
      opts.update(Merb::Const::DEFAULT_SEND_FILE_OPTIONS.merge(opts))
      disposition = opts[:disposition].dup || 'attachment'
      disposition << %(; filename="#{opts[:filename] ? opts[:filename] : File.basename(file)}")
      headers.update(
        'Content-Type'              => opts[:type].strip,  # fixes a problem with extra '\r' with some browsers
        'Content-Disposition'       => disposition,
        'Content-Transfer-Encoding' => 'binary'
      )
      Proc.new do |response|
        file = File.open(file, 'rb')
        while chunk = file.read(16384)
          response.write chunk
        end
        file.close
      end
    end

    # Send binary data over HTTP to the user as a file download.
    #
    # May set content type, apparent file name, and specify whether to
    # show data inline or download as an attachment.
    #
    # @param [String] data Raw data to send as a file.
    # @param [Hash] opts Options for sending the data.
    # @option opts [String] :disposition ("attachment")
    #   The disposition of the file send.
    # @option opts [String] :filename
    #   The name to use for the file.
    # @option opts [String] :type
    #   The content type.
    #
    # @return [String] The raw data passed in.
    #
    # @api public
    def send_data(data, opts={})
      opts.update(Merb::Const::DEFAULT_SEND_FILE_OPTIONS.merge(opts))
      disposition = opts[:disposition].dup || 'attachment'
      disposition << %(; filename="#{opts[:filename]}") if opts[:filename]
      headers.update(
        'Content-Type'              => opts[:type].strip,  # fixes a problem with extra '\r' with some browsers
        'Content-Disposition'       => disposition,
        'Content-Transfer-Encoding' => 'binary'
      )
      data
    end

    # Streams a file over HTTP.
    #
    # @param [Hash] opts Options for the file streaming.
    # @option opts [String] :disposition ("attachment")
    #   The disposition of the file send.
    # @option opts [String] :type
    #   The content type.
    # @option opts [Numeric] :content_length
    #   The length of the content to send.
    # @option opts [String] :filename
    #   The name to use for the streamed file.
    # @param &stream A block that, when called, will return an object that
    #   responds to `#get_lines` for streaming.
    #
    # @example Use with Amazon S3:
    #     stream_file({ :filename => file_name, :type => content_type,
    #       :content_length => content_length }) do |response|
    #       AWS::S3::S3Object.stream(user.folder_name + "-" + user_file.unique_id, bucket_name) do |chunk|
    #         response.write chunk
    #       end
    #     end
    #
    # @api public
    def stream_file(opts={}, &stream)
      opts.update(Merb::Const::DEFAULT_SEND_FILE_OPTIONS.merge(opts))
      disposition = opts[:disposition].dup || 'attachment'
      disposition << %(; filename="#{opts[:filename]}")
      headers.update(
        'Content-Type'              => opts[:type].strip,  # fixes a problem with extra '\r' with some browsers
        'Content-Disposition'       => disposition,
        'Content-Transfer-Encoding' => 'binary',
        # Rack specification requires header values to respond to :each
        'CONTENT-LENGTH'            => opts[:content_length].to_s
      )
      Proc.new do |response|
        stream.call(response)
      end
    end

    # Uses the nginx specific `X-Accel-Redirect` header to send a file directly
    # from nginx.
    #
    # Unless Content-Disposition is set before calling this method, it is
    # set to attachment with streamed file name.
    #
    # For more information, see:
    #
    # * The {http://wiki.nginx.org/NginxXSendfile nginx wiki}
    # * A {http://gist.github.com/11225 sample gist}
    # * An {http://github.com/michaelklishin/nginx-x-accel-redirect-example-application/tree/master example application} on GitHub
    #
    # @param [String] path Path to file to send to the client.
    # @param [String] content_type content type header value. By default
    #   is set to empty string to let Nginx detect it.
    #
    # @return [String] Precisely a single space.
    #
    # @api public
    def nginx_send_file(path, content_type = "")
      # Let Nginx detect content type unless it is explicitly set
      headers['Content-Type']        = content_type
      headers["Content-Disposition"] ||= "attachment; filename=#{path.split('/').last}"
      
      headers['X-Accel-Redirect']    = path
      
      return ' '
    end  

    # Sets a cookie to be included in the response.
    #
    # If you need to set a cookie, then use the `cookies` hash.
    #
    # @param [#to_s] name A name for the cookie.
    # @param [#to_s] value A value for the cookie.
    # @param [#gmtime, #strftime, Hash] expires An expiration time for the
    #   cookie, or a hash of cookie options.
    #
    # @api public
    def set_cookie(name, value, expires)
      options = expires.is_a?(Hash) ? expires : {:expires => expires}
      cookies.set_cookie(name, value, options)
    end

    # Marks a cookie as deleted and gives it an expires stamp in the past.
    #
    # This method is used primarily internally in Merb. Use the `cookies`
    # hash to manipulate cookies instead.
    #
    # @param [#to_s] name A name for the cookie to delete.
    #
    # @api public
    def delete_cookie(name)
      set_cookie(name, nil, Merb::Const::COOKIE_EXPIRED_TIME)
    end

    # Escapes the string representation of `obj` and escapes it for use in XML.
    #
    # @param [#to_s] obj The object to escape for use in XML.
    #
    # @return [String] The escaped object.
    #
    # @api public
    def escape_xml(obj)
      Merb::Parse.escape_xml(obj.to_s)
    end
    alias h escape_xml
    alias escape_html escape_xml
    
    private

    # Marks an output method that only runs on the Mongrel webserver.
    #
    # @raise [NotImplemented] The Rack adapter is not mongrel.
    #
    # @api private
    def only_runs_on_mongrel!
      unless Merb::Config[:log_stream] == 'mongrel'
        raise(Merb::ControllerExceptions::NotImplemented, "Current Rack adapter is not mongrel. cannot support this feature")
      end
    end

    # Process a redirect url with options, appending messages onto the url as query params.
    #
    # @param [String] url The URL being redirected to.
    # @param [Hash] opts An options hash.
    # @option opts [Hash] :message
    #   A hash of key/value strings to be passed along within the redirect
    #   query params.
    # @option opts [String] :notice
    #   A shortcut to passing `:message => {:notice => "..."}`
    # @option opts [String] :error
    #   A shortcut to passing `:message => {:error => "..."}`
    # @option opts [String] :success
    #   A shortcut to passing `:message => {:success => "..."}`
    #
    # @return [String] The new URL with messages attached
    #
    # @api private
    def handle_redirect_messages(url, opts={})
      opts = opts.dup

      # check opts for message shortcut keys (and assign them to message)
      [:notice, :error, :success].each do |message_key|
        if opts[message_key]
          opts[:message] ||= {}
          opts[:message][message_key] = opts[message_key]
        end
      end
      
      # append message query param if message is passed
      if opts[:message]
        notice = Merb::Parse.escape([Marshal.dump(opts[:message])].pack("m"))
        u = ::URI.parse(url)
        u.query = u.query ? "#{u.query}&_message=#{notice}" : "_message=#{notice}"
        url = u.to_s
      end
      
      url
    end
  end
end
