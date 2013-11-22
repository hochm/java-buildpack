# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'java_buildpack/diagnostics'
require 'java_buildpack/diagnostics/logger_factory'
require 'java_buildpack/util'
require 'java_buildpack/util/file_cache'
require 'monitor'
require 'net/http'
require 'tmpdir'
require 'uri'
require 'yaml'

module JavaBuildpack::Util

  # A cache for downloaded files that is configured to use a filesystem as the backing store. This cache uses standard
  # file locking (<tt>File.flock()</tt>) in order ensure that mutation of files in the cache is non-concurrent across
  # processes. Reading downloaded files happens concurrently so read performance is not impacted.
  #
  # This class is not thread safe. File locking does not serialise threads in a single process.
  #
  # References:
  # * {https://en.wikipedia.org/wiki/HTTP_ETag ETag Wikipedia Definition}
  # * {http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html HTTP/1.1 Header Field Definitions}
  class DownloadCache # rubocop:disable ClassLength

    # Creates an instance of the cache that is backed by the filesystem rooted at +cache_root+
    #
    # @param [String] cache_root the filesystem root for downloaded files to be cached in
    def initialize(cache_root = Dir.tmpdir)
      @cache_root = cache_root
      @logger = JavaBuildpack::Diagnostics::LoggerFactory.get_logger
    end

    # Retrieves an item from the cache. Yields an open file containing the item's content or raises an exception if
    # the item cannot be retrieved.
    #
    # @param [String] uri the uri of the item
    # @yieldparam [File] file_data the file representing the cached item. In order to ensure that the file is not changed or
    #                    deleted while it is being used, the cached item can only be accessed as part of a block.
    # @return [void]
    def get(uri)
      file_cache = file_cache(uri)

      success = false
      until success
        success = file_cache.lock_shared do |immutable_file_cache|
          deliver(uri, immutable_file_cache) do |file_data|
            yield file_data
          end
        end

        unless success
          file_cache.lock_exclusive do |mutable_file_cache|
            download(uri, mutable_file_cache)
          end
        end
      end
    end

    # Remove an item from the cache
    #
    # @param [String] uri the URI of the item
    # @return [void]
    def evict(uri)
      file_cache(uri).destroy
    end

    private

    CACHE_CONFIG = '../../../config/cache.yml'.freeze

    INTERNET_DETECTION_RETRY_LIMIT = 5

    DOWNLOAD_RETRY_LIMIT = 5

    TIMEOUT_SECONDS = 10

    HTTP_OK = '200'.freeze

    HTTP_NOT_MODIFIED = '304'.freeze

    HTTP_ERRORS = [
        EOFError,
        Errno::ECONNABORTED,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EHOSTDOWN,
        Errno::EHOSTUNREACH,
        Errno::EINVAL,
        Errno::ENETDOWN,
        Errno::ENETRESET,
        Errno::ENETUNREACH,
        Errno::ENONET,
        Errno::ENOTCONN,
        Errno::EPIPE,
        Errno::ETIMEDOUT,
        Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError,
        Net::ProtocolError,
        SocketError,
        Timeout::Error
    ].freeze

    @@monitor = Monitor.new
    @@internet_checked = false
    @@internet_up = true

    def file_cache(uri)
      FileCache.new(@cache_root, uri)
    end

    def deliver(uri, immutable_file_cache)
      success = false
      if immutable_file_cache.cached? && !immutable_file_cache.has_etag? && !immutable_file_cache.has_last_modified?
        success = true
      elsif DownloadCache.use_internet?
        request = Net::HTTP::Head.new(uri)
        add_headers(request, immutable_file_cache)

        issue_http_request(request, uri) do |_, response_code|
          success = true if response_code == HTTP_NOT_MODIFIED
        end
      end
      if success
        immutable_file_cache.data do |file_data|
          yield file_data
        end
      end
      success
    end

    def add_headers(request, immutable_file_cache)
      immutable_file_cache.any_etag do |etag_content|
        request['If-None-Match'] = etag_content
      end

      immutable_file_cache.any_last_modified do |last_modified_content|
        request['If-Modified-Since'] = last_modified_content
      end
    end

    def self.retry_limit
      @@monitor.synchronize do
        @@internet_checked ? DOWNLOAD_RETRY_LIMIT : INTERNET_DETECTION_RETRY_LIMIT
      end
    end

    def self.use_internet?
      @@monitor.synchronize do
        if !@@internet_checked
          remote_downloads_configuration = get_configuration['remote_downloads']
          if remote_downloads_configuration == 'disabled'
            store_internet_availability false
            false
          elsif remote_downloads_configuration == 'enabled'
            true
          else
            fail "Invalid remote_downloads configuration: #{remote_downloads_configuration}"
          end
        else
          @@internet_up
        end
      end
    end

    def self.get_configuration
      expanded_path = File.expand_path(CACHE_CONFIG, File.dirname(__FILE__))
      YAML.load_file(expanded_path)
    end

    def self.http_options(rich_uri)
      options = {}
      @@monitor.synchronize do
        # Beware known problems with timeouts: https://www.ruby-forum.com/topic/143840
        options = { read_timeout: TIMEOUT_SECONDS, connect_timeout: TIMEOUT_SECONDS, open_timeout: TIMEOUT_SECONDS } unless @@internet_checked
      end
      options.merge(use_ssl: use_ssl?(rich_uri))
    end

    def self.use_ssl?(rich_uri)
      rich_uri.scheme == 'https'
    end

    def issue_http_request(request, uri, &block)
      Net::HTTP.start(*start_parameters(uri)) do |http|
        retry_http_request(http, request, &block)
      end
    end

    def start_parameters(uri)
      rich_uri = URI(uri)
      return rich_uri.host, rich_uri.port, DownloadCache.http_options(rich_uri) # rubocop:disable RedundantReturn
    end

    def retry_http_request(http, request, &block)
      retry_limit = DownloadCache.retry_limit
      1.upto(retry_limit) do |try|
        begin
          http.request request do |response|
            response_code = response.code
            if response_code == HTTP_OK || response_code == HTTP_NOT_MODIFIED
              yield response, response_code
            else
              fail "Bad HTTP response: #{response_code}"
            end
          end
        rescue String, *HTTP_ERRORS => ex
          handle_failure(ex, try, retry_limit, &block)
        end
      end
    end

    def handle_failure(exception, try, retry_limit)
      @logger.debug { "HTTP request attempt #{try} of #{retry_limit} failed: #{exception.message}" }
      if try == retry_limit
        @@monitor.synchronize do
          if @@internet_checked
            fail exception
          else
            DownloadCache.store_internet_availability false
            yield exception, exception.message
          end
        end
      end
    end

    def self.store_internet_availability(internet_up)
      @@monitor.synchronize do
        @@internet_up = internet_up
        @@internet_checked = true
      end
      internet_up
    end

    def self.clear_internet_availability
      @@monitor.synchronize do
        @@internet_checked = false
      end
    end

    def download(uri, mutable_file_cache)
      if DownloadCache.use_internet?
        request = Net::HTTP::Get.new(uri)

        issue_http_request(request, uri) do |response, response_code|
          if response_code == HTTP_OK
            DownloadCache.write_response(mutable_file_cache, response)
          else
            # Shouldn't get 304 on a true download attempt
            fail "Unexpected HTTP response code: #{response_code}"
          end
        end
      else
        look_aside(uri, mutable_file_cache)
      end
    end

    def self.write_response(mutable_file_cache, response)
      mutable_file_cache.persist_any_etag response['Etag']
      mutable_file_cache.persist_any_last_modified response['Last-Modified']

      mutable_file_cache.persist_data do |cached_file|
        response.read_body do |chunk|
          cached_file.write(chunk)
        end
      end
    end

    # A download has failed, so check the read-only buildpack cache for the file
    # and use the copy there if it exists.
    def look_aside(uri, mutable_file_cache)
      @logger.debug "Unable to download from #{uri}. Looking in buildpack cache."
      key = URI.escape(uri, '/')
      stashed = File.join(ENV['BUILDPACK_CACHE'], 'java-buildpack', "#{key}.cached")
      @logger.debug { "Looking in buildpack cache for file '#{stashed}'" }
      if File.exist? stashed
        mutable_file_cache.persist_file stashed
        @logger.debug "Using copy of #{uri} from buildpack cache."
      else
        message = "Buildpack cache does not contain #{uri}. Failing the download."
        @logger.error message
        @logger.debug { "Buildpack cache contents:\n#{`ls -lR #{File.join(ENV['BUILDPACK_CACHE'], 'java-buildpack')}`}" }
        fail message
      end
    end

  end
end
