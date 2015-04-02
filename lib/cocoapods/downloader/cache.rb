require 'fileutils'
require 'tmpdir'

module Pod
  module Downloader
    class Cache
      Result = Struct.new(:location, :spec, :checkout_options)

      attr_reader :root

      def initialize(root)
        @root = root
        root.mkpath unless root.exist?
      end

      def download_pod(name_or_spec, released = false, downloader_opts = nil, head = false)
        spec = nil
        if name_or_spec.is_a? Pod::Specification
          spec = name_or_spec.root
          name, version, downloader_opts = spec.name, spec.version, spec.source.dup
        else
          name = Specification.root_name(name_or_spec.to_s)
        end

        raise ArgumentError, 'Must give spec for a released download.' if released && !spec

        result = Result.new

        if !head && result.location = path_for_pod(name, version, downloader_opts)
          result.checkout_options = downloader_opts
          result.spec = spec || begin
                                  cached_spec = path_for_spec(name, version, downloader_opts)
                                  cached_spec.file? && Specification.from_file(cached_spec)
                                end
          return result if result.location.directory?
        end

        in_tmpdir do |target|
          result.checkout_options = download(name, target, downloader_opts, head)

          if released
            result.location = destination = path_for_pod(name, version)
            copy_and_clean(target, destination, spec)
            write_spec spec, path_for_spec(name, version)
          else
            podspecs = Sandbox::PodspecFinder.new(target).podspecs
            podspecs[name] = spec if spec
            podspecs.each do |_, found_spec|
              destination = path_for_pod(found_spec.name, nil, result.checkout_options)
              copy_and_clean(target, destination, found_spec)
              write_spec found_spec, path_for_spec(found_spec.name, nil, result.checkout_options)
              if name == found_spec.name
                result.location = destination
                result.spec = found_spec
              end
            end
          end
        end

        result
      rescue Informative
      rescue
        UI.notice("Error installing #{name}")
        raise
      end

      private

      def cache_key(pod_name, version = nil, downloader_opts = nil)
        raise ArgumentError unless pod_name || (!version && !downloader_opts)

        if version
          "Release/#{pod_name}/#{version}"
        elsif downloader_opts
          opts = downloader_opts.to_a.sort_by(&:first).map { |k, v| "#{k}=#{v}" }.join('-').gsub(/#{File::SEPARATOR}+/, '+')
          "External/#{pod_name}/#{opts}"
        end
      end

      def path_for_pod(name, version = nil, downloader_opts = nil)
        root + cache_key(name, version, downloader_opts)
      end

      def path_for_spec(name, version = nil, downloader_opts = nil)
        root + 'Specs' + cache_key(name, version, downloader_opts)
      end

      def download(name, target, params, head)
        downloader = Downloader.for_target(target, params)
        if head
          unless downloader.head_supported?
            raise Informative, "The pod '" + name + "' does not " \
              'support the :head option, as it uses a ' + downloader.name +
              ' source. Remove that option to use this pod.'
          end
          downloader.download_head
        else
          downloader.download
        end

        if downloader.options_specific? && !head
          params
        else
          downloader.checkout_options
        end
      end

      def in_tmpdir(&blk)
        tmpdir = Pathname(Dir.mktmpdir)
        blk.call(tmpdir)
      ensure
        FileUtils.remove_entry(tmpdir) if tmpdir.exist?
      end

      def copy_and_clean(source, destination, spec)
        specs_by_platform = {}
        spec.available_platforms.each do |platform|
          specs_by_platform[platform] = [spec, *spec.recursive_subspecs].select { |ss| ss.supported_on_platform?(platform) }
        end
        destination.parent.mkpath unless destination.parent.exist?
        FileUtils.cp_r(source, destination)
        Sandbox::PodDirCleaner.new(destination, specs_by_platform).clean!
      end

      def write_spec(spec, path)
        path = path.sub_ext('.podspec.json')
        FileUtils.mkdir_p path.dirname
        path.open('w') { |f| f.write spec.to_pretty_json }
      end
    end
  end
end
