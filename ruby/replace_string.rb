#!/usr/bin/env ruby

require 'optparse'
require 'fileutils'

class ReplaceString
  VERSION = '1.0.0'
  TIMESTAMP = Time.now.strftime('%c')

  DELIMITERS = ['/',  '#', '|', ':' '~', '!', '%', ',', '@'].freeze # safe delimiters for regex

  def initialize
    @do_query = true
    @do_backups = true
    @bak = 'bak'
    @verbose = false
    @show_rules = true
    @paragraph_mode = false
    @delete_empty_lines = false
    @substitutions = []
    @files = []
    @running_as_root = Process.uid == 0
  end

  def parse_options
    OptionParser.new do |opts|
      opts.banner = usage_banner

      opts.on('-s PATTERN', 'Substitution in Ruby format (e.g., "s/old/new/g")') do |pattern|
        @substitutions << pattern
      end

      opts.on('-S FILE', 'File containing substitution patterns') do |file|
        read_substitution_patterns(file)
      end

      opts.on('-f FILES', Array, 'Space-separated list of files to process') do |files|
        @files.concat(files)
      end

      opts.on('-F FILE', 'File containing list of files to process') do |file|
        read_file_list(file)
      end

      opts.on('-v', 'Verbose mode') { @verbose = true }
      opts.on('-b SUFFIX', 'Backup file suffix') { |suffix| @bak = suffix.sub(/^\./, '') }
      opts.on('-nb', 'Don\'t create backup files') { @do_backups = false }
      opts.on('-nr', 'Don\'t print substitution rules') { @show_rules = false }
      opts.on('-nq', 'Don\'t query, replace without asking') { @do_query = false }
      opts.on('-p', 'Paragraph mode (multi-line matching)') { @paragraph_mode = true }
      opts.on('-del', 'Delete empty lines after replacement') { @delete_empty_lines = true }
    end.parse!

    # Validate that we have files to process
    if @files.empty?
      abort " >>> ERROR: No files specified. Use -f or -F option to specify files to process."
    end
  end

  def main
    if @files.empty?
      show_parameters("default")
      exit unless yes_or_no?("\nDo you want to proceed with these default values?")
    end

    @verbose = true if @do_query
    @show_rules = true if @verbose

    warn_if_root
    setup_interrupt_handler
    validate_and_filter_files

    display_substitution_rules if @show_rules
    process_files
  end

  private

  def process_files
    file_count = 0
    @files.each do |file|
      file_count += 1
      process_single_file(file, file_count)
    end
    puts "  processed #{file_count} files"
  end

  def process_single_file(file, file_nr)
    temp_file = create_temp_filename
    touched = false
    quit = false
    replace_all = false

    display_file_header(file, file_nr) if @verbose

    puts "DEBUG: Processing file: #{file}" if @verbose
    puts "DEBUG: Paragraph mode: #{@paragraph_mode}" if @verbose

    original_stats = File.stat(file)
    
    File.open(temp_file, 'w') do |new_file|
      if @paragraph_mode
        content = File.read(file)
        original_content = content.dup
        
        substitution_count = 0
        @substitutions.each do |pattern|
          next if pattern =~ /^\s*[#;]/
          next if pattern.strip.empty?
          
          begin
            if pattern =~ /^s(.)/
              delimiter = $1
              delimiter_regex = /#{Regexp.escape(delimiter)}/
              parts = pattern[2..-1].split(delimiter_regex, -1)
              
              if parts.length == 3
                search, replace, flags = parts
                
                # Don't escape the search pattern - it's already a regex
                search_regex = search
                
                # Handle replacement backreferences properly
                replace = replace.gsub(/\$(\d+)/) { "\\#{$1}" }
                
                # Set regex flags
                regex_flags = Regexp::MULTILINE  # Always use multiline mode
                regex_flags |= Regexp::IGNORECASE if flags&.include?('i')
                regex_flags |= Regexp::EXTENDED if flags&.include?('x')
                
                begin
                  regex = Regexp.new(search_regex, regex_flags)
                  
                  # Apply substitution
                  modified = content.gsub(regex) do |match|
                    match_data = Regexp.last_match
                    result = replace.dup
                    result.gsub!(/\\(\d+)/) { |m| match_data[$1.to_i] || m }
                    result
                  end
                  
                  if modified != content
                    content = modified
                    count = 1 # Count each successful substitution
                    substitution_count += count
                  end
                rescue RegexpError => e
                  warn " >>> ERROR: Invalid regular expression '#{search_regex}': #{e.message}"
                end
              end
            end
          rescue => e
            warn " >>> ERROR: Failed to process pattern '#{pattern}': #{e.message}"
            warn e.backtrace.join("\n") if @verbose
          end
        end
        
        if substitution_count > 0
          if @do_query
            touched, quit, replace_all = handle_query_mode(
              original_content, content, 1, substitution_count, replace_all
            )
            content = original_content unless touched
          else
            touched = true
          end
        end
        
        new_file.write(content)
      else
        # Original line-by-line processing
        File.foreach(file).with_index(1) do |line, line_nr|
          line.chomp!
          original_line = line.dup

          next if should_skip_line?(line)

          substitution_count = apply_substitutions(line)
          
          if substitution_count > 0
            if @do_query
              touched, quit, replace_all = handle_query_mode(
                original_line, line, line_nr, substitution_count, replace_all
              )
              line = original_line unless touched
            else
              display_substitution(original_line, line, line_nr, substitution_count) if @verbose
              touched = true
            end
          end

          break if quit
          write_line(new_file, line, substitution_count)
        end
      end
    end

    handle_file_modifications(file, temp_file, touched, quit, original_stats)
  ensure
    File.unlink(temp_file) if File.exist?(temp_file)
  end

  def handle_query_mode(original_line, new_line, line_nr, subs_count, replace_all)
    printf("line %4d : \"%s\"\n", line_nr, original_line)
    puts "        ==> \"#{new_line}\""
    print "\n  (#{subs_count} substitutions) "

    if replace_all
      puts "  substituted!\n\n"
      return [true, false, replace_all]
    end

    touched, quit, new_replace_all = ask_user('  substitute? ', replace_all)
    
    if touched
      puts "  substituted!\n\n"
    else
      puts "  not modified!\n\n"
    end
    
    return [touched, quit, new_replace_all]
  end

  def apply_substitutions(line)
    count = 0
    @substitutions.each do |pattern|
      # Skip comments and empty lines
      next if pattern =~ /^\s*[#;]/
      next if pattern.strip.empty?

      begin
        if pattern =~ /^s(.)/
          delimiter = $1
          delimiter_regex = /#{Regexp.escape(delimiter)}/
          
          parts = pattern[2..-1].split(delimiter_regex, -1)
          
          if parts.length == 3
            search, replace, flags = parts
            puts "DEBUG: Applying pattern: #{pattern}" if @verbose
            puts "DEBUG: Search: #{search.inspect}" if @verbose
            puts "DEBUG: Replace: #{replace.inspect}" if @verbose
            puts "DEBUG: Flags: #{flags.inspect}" if @verbose
            
            # Convert Perl variables to Ruby format
            replace = replace.gsub(/\$(\d+)/, '\\\\\\1')  # $1 -> \1
            
            # Handle flags - ensure 'm' flag works for multiline
            regex_flags = 0
            if flags
              regex_flags |= Regexp::IGNORECASE if flags.include?('i')
              regex_flags |= Regexp::MULTILINE if flags.include?('m')
              # Add EXTENDED mode if 'x' flag is present
              regex_flags |= Regexp::EXTENDED if flags.include?('x')
            end
            
            # Always add multiline mode if pattern contains newlines
            regex_flags |= Regexp::MULTILINE if search.include?('\n')
            
            puts "DEBUG: Regex flags: #{regex_flags}" if @verbose
            
            # Compile and apply the regex
            regex = Regexp.new(search, regex_flags)
            original = line.dup
            result = line.gsub!(regex, replace)
            
            if result
              puts "DEBUG: Match found and replaced" if @verbose
              count += if flags&.include?('g')
                        original.scan(regex).length
                      else
                        1
                      end
            end
          else
            warn " >>> WARNING: Malformed substitution (expected 3 parts): #{pattern}"
          end
        else
          warn " >>> WARNING: Unknown command (not a substitution): #{pattern}"
        end
      rescue RegexpError => e
        warn " >>> ERROR: Invalid regular expression in '#{pattern}': #{e.message}"
      rescue => e
        warn " >>> ERROR: Failed to process '#{pattern}': #{e.message}"
      end
    end
    puts "DEBUG: Total substitutions for this section: #{count}" if @verbose
    count
  end

  def create_temp_filename
    "/tmp/__tmp_#{Process.pid}_file"
  end

  def handle_file_modifications(file, temp_file, touched, quit, original_stats)
    if touched && !quit
      puts "file \"#{file}\" was modified!\n\n"
      backup_file(file) if @do_backups
      FileUtils.mv(temp_file, file)
      restore_permissions(file, original_stats)
    else
      puts "file \"#{file}\" not modified!\n\n"
    end
  end

  def backup_file(file)
    backup = "#{file}.#{@bak}"
    FileUtils.cp(file, backup, preserve: true)
  end

  def restore_permissions(file, stats)
    File.chmod(stats.mode, file)
    File.chown(stats.uid, stats.gid, file) if @running_as_root
  end

  def yes_or_no?(prompt)
    print "#{prompt} (y/n) "
    gets.chomp.downcase.start_with?('y')
  end

  def ask_user(prompt, replace_all)
    print "#{prompt} (y/n/!/q) "
    response = gets.chomp.downcase
    case response
    when '!'
      # Set replace_all flag and return true to replace current match
      @replace_all = true
      return [true, false, true]  # [touched, quit, replace_all]
    when 'q'
      # Set quit flag and return false to skip current match
      @quit = true
      return [false, true, false]  # [touched, quit, replace_all]
    when 'y'
      return [true, false, false]  # [touched, quit, replace_all]
    else
      return [false, false, false]  # [touched, quit, replace_all]
    end
  end

  def usage_banner
    <<~BANNER
      Copyright by Tilo Sloboda
      Ruby port of replace_string (#{VERSION})
      Last edited: #{TIMESTAMP}

      USAGE: #{$PROGRAM_NAME} {options} -f filenames
             #{$PROGRAM_NAME} {options} -F filename

      OPTIONS:
        -s PATTERN    Substitution in Ruby format (e.g., "s/old/new/g", "s/(\w+) (\w+)/$2 $1/g")
        -S FILE       File containing substitution patterns

        -f FILES      Space-separated list of files to process
        -F FILE       File containing list of files to process

        -v            Verbose mode
        -b SUFFIX     Backup file suffix (default: #{@bak})
        
        -nb           Don't create backup files
        -nr           Don't print substitution rules
        -nq           Don't query, replace without asking

        -p            Paragraph mode (multi-line matching)
        
        -del          Delete empty lines after replacement
        
        -m REGEXP     Only replace lines matching the given regexp

        -nm REGEXP    Only replace lines NOT matching the given regexp

        -d PATTERN    Duplicate lines matching pattern before substitution

        -mcf          Modify filenames and copy files
                        Each match of reg-exp is considered as a filename
                        which is in another directory. Additional to the
                        search/replace operation, the referenced file will
                        be copied into the same directory as the file which
                        is referencing it.
    BANNER
  end

  def read_substitution_patterns(file)
    File.readlines(file).each do |line|
      next if line.start_with?('#', ';') || line.strip.empty?
      @substitutions << line.chomp
    end
  rescue Errno::ENOENT
    abort " >>> ERROR: Cannot open substitution list file: #{file}"
  end

  def read_file_list(file)
    begin
      File.readlines(file).each do |line|
        # Skip comments and empty lines
        next if line.start_with?('#', ';') || line.strip.empty?
        @files << line.chomp
      end
    rescue Errno::ENOENT
      abort " >>> ERROR: Cannot open file list: #{file}"
    end
    
    if @files.empty?
      abort " >>> ERROR: No valid files found in file list: #{file}"
    end
  end

  def warn_if_root
    if @running_as_root
      warn "\n >>> WARNING: you are running '#{$PROGRAM_NAME}' as ROOT!"
      warn "     UIDs, GIDs and modes will be preserved!\n\n"
    end
  end

  def setup_interrupt_handler
    Signal.trap('INT') do
      if yes_or_no?("\n >>> USER INTERRUPT: do you really want to quit?")
        File.unlink(@temp_file) if @temp_file && File.exist?(@temp_file)
        puts "\n\n ... I just cleaned up ... poof! now I'm dead!\n\n"
        exit 1
      end
    end
  end

  def validate_and_filter_files
    @files.reject! do |file|
      reason = if !File.exist?(file)
                 "file does not exist!"
               elsif File.directory?(file)
                 "this is a directory!"
               elsif File.symlink?(file)
                 "this is a symbolic link!"
               elsif File.pipe?(file)
                 "this is a named pipe!"
               elsif File.socket?(file)
                 "this is a socket!"
               elsif File.zero?(file)
                 "file has zero size!"
               elsif !File.writable?(file)
                 "file is write protected!"
               elsif !File.file?(file)
                 "this is not a plain file!"
               end
      
      if reason
        printf(" >>> WARNING: %-26s - omitting \"%s\"\n", reason, file)
        true
      else
        false
      end
    end
  end

  def display_substitution_rules
    puts "\nSubstitution rules to be applied:"
    @substitutions.each do |rule|
      puts "   #{rule}"
    end
    puts
  end

  def should_skip_line?(line)
    return false unless @match_pattern || @not_match_pattern
    
    if @match_pattern
      !line.match?(@match_pattern)
    elsif @not_match_pattern
      line.match?(@not_match_pattern)
    end
  end

  def write_line(file, line, substitution_count)
    return if @delete_empty_lines && substitution_count > 0 && line.empty?
    file.puts(line)
  end

  def display_file_header(file, file_nr)
    puts "\n########################################"
    puts "file #{file_nr}: \"#{file}\""
    puts "########################################\n\n"
  end

  def show_parameters(note)
    puts usage_banner
    puts "\nCurrent settings:"
    puts "  Backup suffix: #{@bak}"
    puts "  Query mode: #{@do_query ? 'enabled' : 'disabled'}"
    puts "  Backup files: #{@do_backups ? 'enabled' : 'disabled'}"
    puts "  Verbose mode: #{@verbose ? 'enabled' : 'disabled'}"
    puts "  Show rules: #{@show_rules ? 'enabled' : 'disabled'}"
    puts "  Paragraph mode: #{@paragraph_mode ? 'enabled' : 'disabled'}"
    puts "  Delete empty lines: #{@delete_empty_lines ? 'enabled' : 'disabled'}"
  end

  # Ruby Options:
  #   -i: ignore case
  #   -x: extended regex
  #   -m: multiline
  #   -o: perform interpolation only once
  # 
  # usage:
  #    expression = 's/(\w+)\s+(\w+)/\2 \1/igm'
  #    parse_expression(expression)
  #    => [/(\w+)\s+(\w+)/mi, "\\2 \\1", ["i", "g", "m"]]
  #
  # Regexp.new only processes the flags that it understands
  #
  def parse_expression(expression)
    raise "Not a valid expression: #{expression}" unless expression.start_with?('s')
    delimiter = expression[1]
    raise "Inconsistent delimiters: #{expression}" unless expression.count(delimiter) == 3

    _s, regex_str, replacement_str, flag_str = expression.split(delimiter)
    # Convert Perl-style $1, $2 to Ruby-style \1, \2 in replacement string
    replacement = replacement_str.gsub(/\$(\d+)/) { "\\#{$1}" }
    flags = flag_str.split(//)
    options = translate_regexp_flags(flags)
    [Regexp.new(regex_str, options), replacement, flags]
  end

  # Ruby uses the Onigmo library for regular expressions.
  # Ruby's regular expression engine is based on Onigmo, a fork of Oniguruma.
  # https://github.com/ruby/ruby/blob/master/regparse.c
  # https://github.com/k-takata/Onigmo/blob/1d7ee878b3e4a9e41bf9825c937ae6cf0a9cd68c/onigmo.h#L453
  #
  # Options for Regexp.new:
  #  - EXTENDED
  #  - FIXEDENCODING
  #  - IGNORECASE
  #  - MULTILINE
  #  - NOENCODING
  #
  def translate_regexp_flags(flags_array)
    option_int = 0

    flags_array.each do |flag|
      case flag
      when 'i'
        option_int |= Regexp::IGNORECASE
      when 'm'
        option_int |= Regexp::MULTILINE
      when 'x'
        option_int |= Regexp::EXTENDED
      # 'g' is handled outside of Regexp.new, so we ignore it here.
      end
    end

    option_int
  end
end

# Run the program
if __FILE__ == $PROGRAM_NAME
  replace_string = ReplaceString.new
  replace_string.parse_options
  replace_string.main
end
