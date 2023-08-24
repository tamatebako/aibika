# frozen_string_literal: true

# Aibika front-end
module Aibika
  def self.parseargs(argv)
    usage = <<~USG
      aibika [options] script.rb

      Aibika options:

      --help             Display this information.
      --quiet            Suppress output while building executable.
      --verbose          Show extra output while building executable.
      --version          Display version number and exit.

      Packaging options:

      --dll dllname      Include additional DLLs from the Ruby bindir.
      --add-all-core     Add all core ruby libraries to the executable.
      --gemfile <file>   Add all gems and dependencies listed in a Bundler Gemfile.
      --no-enc           Exclude encoding support files
      --allow-self       Include self (aibika gem) if detected or specified
          This option is required only if aibika gem is deployed as a part
          of broader bundled your solution

      Gem content detection modes:

      --gem-minimal[=gem1,..]  Include only loaded scripts
      --gem-guess=[gem1,...]   Include loaded scripts & best guess (DEFAULT)
      --gem-all[=gem1,..]      Include all scripts & files
      --gem-full[=gem1,..]     Include EVERYTHING
      --gem-spec[=gem1,..]     Include files in gemspec (Does not work with Rubygems 1.7+)

        minimal: loaded scripts
        guess: loaded scripts and other files
        all: loaded scripts, other scripts, other files (except extras)
        full: Everything found in the gem directory

      --[no-]gem-scripts[=..]  Other script files than those loaded
      --[no-]gem-files[=..]    Other files (e.g. data files)
      --[no-]gem-extras[=..]   Extra files (README, etc.)

        scripts: .rb/.rbw files
        extras: C/C++ sources, object files, test, spec, README
        files: all other files

      Auto-detection options:

      --no-dep-run       Don't run script.rb to check for dependencies.
      --no-autoload      Don't load/include script.rb's autoloads.
      --no-autodll       Disable detection of runtime DLL dependencies.

      Output options:

      --output <file>    Name the exe to generate. Defaults to ./<scriptname>.exe.
      --no-lzma          Disable LZMA compression of the executable.
      --innosetup <file> Use given Inno Setup script (.iss) to create an installer.

      Executable options:

      --windows          Force Windows application (rubyw.exe)
      --console          Force console application (ruby.exe)
      --chdir-first      When exe starts, change working directory to app dir.
      --icon <ico>       Replace icon with a custom one.
      --debug            Executable will be verbose.
      --debug-extract    Executable will unpack to local dir and not delete after.
    USG

    while (arg = argv.shift)
      case arg
      when /\A--(no-)?lzma\z/
        @options[:lzma_mode] = !::Regexp.last_match(1)
      when /\A--no-dep-run\z/
        @options[:run_script] = false
      when /\A--add-all-core\z/
        @options[:add_all_core] = true
      when /\A--output\z/
        @options[:output_override] = Pathname(argv.shift)
      when /\A--dll\z/
        @options[:extra_dlls] << argv.shift
      when /\A--quiet\z/
        @options[:quiet] = true
      when /\A--verbose\z/
        @options[:verbose] = true
      when /\A--windows\z/
        @options[:force_windows] = true
      when /\A--console\z/
        @options[:force_console] = true
      when /\A--no-autoload\z/
        @options[:load_autoload] = false
      when /\A--chdir-first\z/
        @options[:chdir_first] = true
      when /\A--icon\z/
        @options[:icon_filename] = Pathname(argv.shift)
        Aibika.fatal_error "Icon file #{icon_filename} not found.\n" unless icon_filename.exist?
      when /\A--gemfile\z/
        @options[:gemfile] = Pathname(argv.shift)
        Aibika.fatal_error "Gemfile #{gemfile} not found.\n" unless gemfile.exist?
      when /\A--innosetup\z/
        @options[:inno_script] = Pathname(argv.shift)
        Aibika.fatal_error "Inno Script #{inno_script} not found.\n" unless inno_script.exist?
      when /\A--no-autodll\z/
        @options[:autodll] = false
      when /\A--version\z/
        puts "Aibika #{VERSION}"
        exit 0
      when /\A--no-warnings\z/
        @options[:show_warnings] = false
      when /\A--debug\z/
        @options[:debug] = true
      when /\A--debug-extract\z/
        @options[:debug_extract] = true
      when /\A--\z/
        @options[:arg] = ARGV.dup
        ARGV.clear
      when /\A--(no-)?enc\z/
        @options[:enc] = !::Regexp.last_match(1)
      when /\A--(no-)?gem-(\w+)(?:=(.*))?$/
        negate = ::Regexp.last_match(1)
        group = ::Regexp.last_match(2)
        list = ::Regexp.last_match(3)
        @options[:gem] ||= []
        @options[:gem] << [negate, group.to_sym, list && list.split(',')]
      when /\A--help\z/, /\A--./
        puts usage
        exit 0
      else
        @options[:files] << if __FILE__.respond_to?(:encoding)
                              arg.dup.force_encoding(__FILE__.encoding)
                            else
                              arg
                            end
      end
    end

    if Aibika.debug_extract && Aibika.inno_script
      Aibika.fatal_error 'The --debug-extract option conflicts with use of Inno Setup'
    end

    if Aibika.lzma_mode && Aibika.inno_script
      Aibika.fatal_error 'LZMA compression must be disabled (--no-lzma) when using Inno Setup'
    end

    if !Aibika.chdir_first && Aibika.inno_script
      Aibika.fatal_error 'Chdir-first mode must be enabled (--chdir-first) when using Inno Setup'
    end

    if files.empty?
      puts usage
      exit 1
    end

    @options[:files].map! do |path|
      path = path.encode('UTF-8').tr('\\', '/')
      if File.directory?(path)
        # If a directory is passed, we want all files under that directory
        path = "#{path}/**/*"
      end
      files = Dir[path]
      Aibika.fatal_error "#{path} not found!" if files.empty?
      files.map { |pth| Pathname(pth).expand }
    end.flatten!
  end

  def self.msg(msg)
    puts "=== #{msg}" unless Aibika.quiet
  end

  def self.verbose_msg(msg)
    puts msg if Aibika.verbose && !Aibika.quiet
  end

  def self.warn(msg)
    msg "WARNING: #{msg}" if Aibika.show_warnings
  end

  def self.fatal_error(msg)
    puts "ERROR: #{msg}"
    exit 1
  end
end
