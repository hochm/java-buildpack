# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright (c) 2013 the original author or authors.
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

require 'fileutils'
require 'java_buildpack/util'

module JavaBuildpack::Util

  # A cache for a single file which uses a filesystem as the backing store. This cache uses standard
  # file locking (<tt>File.flock()</tt>) in order ensure that mutation of files in the cache is non-concurrent across
  # processes.  Reading files happens concurrently so read performance is not impacted.
  #
  # Note: this class is not thread-safe.
  class FileCache

    # Creates an instance of the file cache that is backed by the filesystem rooted at +cache_root+
    #
    # @param [String] cache_root the filesystem root for the file to be cached in
    # @param [String] uri a uri which uniquely identifies the file in the cache root
    def initialize(cache_root, uri)
      FileUtils.mkdir_p(cache_root)
      @cache_root = cache_root

      key = URI.escape(uri, '/')
      @lock = File.join(@cache_root, "#{key}.lock")
      cached = File.join(@cache_root, "#{key}.cached")
      etag = File.join(@cache_root, "#{key}.etag")
      last_modified = File.join(@cache_root, "#{key}.last_modified")

      File.open(@lock, File::CREAT) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        @locked_file_cache = LockedFileCache.new(cached, etag, last_modified)
        lock_file.flock(File::LOCK_SH)
      end

    end

    # Perform an operation with the file cache locked.
    #
    # @yieldparam [LockedFileCache] @locked_file_cache an object which the provided block may use to operate on the file cache under the lock
    def lock
      File.open(@lock, File::CREAT) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        @locked_file_cache.lock_file = lock_file
        begin
          yield @locked_file_cache
        ensure
          @locked_file_cache.lock_file = nil
        end
      end
    end

    # Destroys the file cache.
    def destroy
      lock do |locked_file_cache|
        locked_file_cache.destroy
      end
      LockedFileCache.delete_file @lock
    end

    # This class is used to operate on the file cache under the lock.
    class LockedFileCache

      # Creates an instance of +LockedFileCache+.
      #
      # @param [String] cached file name of the file to contain the cached data
      # @param [String] etag file name of the file to contain any etag
      # @param [String] last_modified file name of the file to contain any last modified timestamp
      def initialize(cached, etag, last_modified)
        @cached = cached
        @etag = etag
        @last_modified = last_modified
      end

      # Sets the open lock file so that it can be downgraded and upgraded.
      attr_writer :lock_file

      # If an etag is provided, stores it in the corresponding file.
      #
      # @param [String, nil] etag_data the etag or +nil+ if there is no etag
      def persist_any_etag(etag_data)
        persist(etag_data, @etag)
      end

      # If a last modified timestamp is provided, stores it in the corresponding file.
      #
      # @param [String, nil] last_modified_data the last modified timestamp or +nil+ if there is no last modified timestamp
      def persist_any_last_modified(last_modified_data)
        persist(last_modified_data, @last_modified)
      end

      # Stores data to be cached.
      def persist_data
        File.open(@cached, File::CREAT | File::WRONLY) do |cached_file|
          yield cached_file
        end
      end

      # Stores data to be cached from a file.
      #
      # @param [String] file the file name of the file whose content is to be cached
      def persist_file(file)
        FileUtils.cp(file, @cached)
      end

      # Returns whether or not data is cached.
      #
      # @return [Boolean] +true+ if and only if data is cached
      def cached?
        File.exists?(@cached)
      end

      # Returns whether or not an etag is stored.
      #
      # @return [Boolean] +true+ if and only if an etag is stored
      def has_etag?
        File.exists?(@etag)
      end

      # Returns whether or not a last modified time stamp is stored.
      #
      # @return [Boolean] +true+ if and only if a last modified time stamp is stored
      def has_last_modified?
        File.exists?(@last_modified)
      end

      # Yields any etag which may be stored.
      def any_etag(&block)
        yield_file_data(@etag, &block)
      end

      # Yields any last modified timestamp which may be stored.
      def any_last_modified(&block)
        yield_file_data(@last_modified, &block)
      end

      # Downgrades the lock from exclusive to shared, yields an open file containing the cached data, then upgrades
      # the lock from shared to exclusive to preserve the +LockedFileCache+ contract.
      def data
        @lock_file.flock(File::LOCK_SH)
        begin
          File.open(@cached, File::RDONLY) do |cached_file|
            yield cached_file
          end
        ensure
          @lock_file.flock(File::LOCK_EX) # FIXME: finally
        end
      end

      # Deletes any files containing cached data, etag, or last modified timestamp.
      def destroy
        LockedFileCache.delete_file @cached
        LockedFileCache.delete_file @etag
        LockedFileCache.delete_file @last_modified
      end

      private

      def persist(data, file)
        unless data.nil?
          File.open(file, File::CREAT | File::WRONLY) do |open_file|
            open_file.write(data)
            open_file.fsync
          end
        end
      end

      def yield_file_data(file)
        if File.exists?(file)
          File.open(file, File::RDONLY) do |open_file|
            yield open_file.read
          end
        end
      end

      def self.delete_file(filename)
        File.delete filename if File.exists? filename
      end

    end

  end

end
