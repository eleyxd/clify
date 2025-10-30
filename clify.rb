#!/usr/bin/env ruby
# encoding: utf-8


require 'open3'
require 'curses'
require 'shellwords'
require 'json'
require 'thread' 
require 'time' 
require 'fileutils' 


TUI_UPDATE_INTERVAL_MS = 100 
PLAYER = 'mplayer' 
REWIND_STEP_SECONDS = 10 
FIFO_PATH = '/tmp/clify-mplayer-fifo'


$player_pid = nil
$curses_win = nil
$drawing_thread = nil


$track_title = "Loading..."
$stream_url = nil 
$ascii_cover = [] 


$playlist_tracks = [] 
$current_track_index = 0
$playlist_action = nil 


$playback_state = {
  start_position: 0.0 
}

$time_data = {
  current: 0.0, 
  total: 0, 
  status: 'Loading',
  start_time: nil,    
  offset: 0.0         
}


$current_volume = 100 
$restart_required = false 



def extract_metadata(data)
    stream_url = data['webpage_url'] || data['url'] 
    
    return nil unless stream_url 

    artist = data['artist'] || data['uploader'] || "Unknown Artist"
    title = data['title'] || "Unknown Title"
    
    track_title = "#{artist.to_s.strip} - #{title.to_s.strip}"
    total_duration = data['duration'].to_i if data['duration']
    thumbnail_url = data['thumbnail']

    { 
      stream_url: stream_url, 
      track_title: track_title, 
      total_duration: total_duration,
      thumbnail_url: thumbnail_url
    }
end

def get_temp_file_path
  File.join('/tmp', "clify_#{Process.pid}_#{$current_track_index}.mp4")
end


def get_track_data_recursive(track_or_entry)
  
  if track_or_entry.is_a?(Hash)
    url = track_or_entry['webpage_url'] || track_or_entry['url']
    is_playlist_item = true
  else
    url = track_or_entry
    is_playlist_item = false
  end
  
  return nil unless url


  proxy = ENV['ALL_PROXY']
  env_opts = proxy ? {"ALL_PROXY" => proxy} : {}

  unless is_playlist_item
    puts "Checking for playlist/set: #{url}..."
    
    playlist_command_array = [
        "yt-dlp", 
        "--flat-playlist", 
        "--dump-single-json", 
        "--no-warnings", 
        Shellwords.escape(url)
    ]
    
    stdout, _, status = Open3.capture3(env_opts, *playlist_command_array)
    
    if status.success?
      begin
        playlist_json = JSON.parse(stdout.lines.last.strip)
        
        if playlist_json['_type'] == 'playlist' && playlist_json['entries'].is_a?(Array)
          
          playlist_items = []
          puts "Playlist detected with #{playlist_json['entries'].size} entries. Processing items..."
          
          playlist_json['entries'].each do |entry|
            item_data = get_track_data_recursive(entry)
            playlist_items << item_data if item_data
          end
          
          return playlist_items
        end
        
      rescue JSON::ParserError
        puts "JSON parse error in playlist check. Assuming single track."
      end
    end
  end


  
  puts "Waiting for stream data (single track): #{url}..."
  
  command_array = [
      "yt-dlp", 
      "-f", 
      "bestaudio", 
      "--dump-json", 
      "--no-warnings", 
      "--no-playlist", 
      Shellwords.escape(url)
  ]
  
  stdout, stderr, status = Open3.capture3(env_opts, *command_array)
  
  unless status.success?
    puts "❌ Error while getting data from yt-dlp for single track:" unless is_playlist_item
    puts stderr unless is_playlist_item
    return nil
  end
  
  begin
    data = JSON.parse(stdout)
    return extract_metadata(data)
    
  rescue JSON::ParserError => e
    puts "❌ Error JSON parsing from yt-dlp. Error: #{e.message}" unless is_playlist_item
    return nil
  end
end



def format_time(seconds)
  return '0:00' if seconds.nil? || seconds.to_i < 0
  seconds = seconds.to_i
  minutes = seconds / 60
  secs = seconds % 60
  "#{minutes}:#{'%02d' % secs}"
end

def get_player_command(file_path)
    
    if PLAYER == 'mplayer'
        FileUtils.rm_f(FIFO_PATH) if File.exist?(FIFO_PATH)
        system("mkfifo #{FIFO_PATH}") 
        
        args = [
            '-novideo',
            '-ao', 'pulse',
            '-slave',        
            '-input', "file=#{FIFO_PATH}", 
            Shellwords.escape(file_path)
        ]
        
    elsif PLAYER == 'mpv'
        # Запасной MPV
        args = [
            '--no-video', '--no-terminal', '--ao=alsa', 
            '--input-ipc-server=/tmp/clify-mpv-socket', Shellwords.escape(file_path)
        ]
    else
        args = [Shellwords.escape(file_path)]
    end
    
    final_cmd = [PLAYER] + args.reject(&:empty?)

    return final_cmd
end



def get_ascii_cover_output(url, width)
  proxy_arg = ""
  
  if proxy = ENV['ALL_PROXY']
      proxy_arg = "-x #{Shellwords.escape(proxy)}" 
  end

  if system('which jp2a > /dev/null 2>&1')
    tool_cmd = 'jp2a'
    renderer_args = "--width=#{width}" 
    
  elsif system('which chafa > /dev/null 2>&1')
    tool_cmd = 'chafa'
    renderer_args = "--size #{width}x30 --fill - --format symbols" 
    
  else
    return ["*** jp2a/chafa не найдены ***"]
  end

  unless system('which curl > /dev/null 2>&1')
    return ["*** curl не найден ***"]
  end

  return [] unless url
  
  curl_cmd = "curl -s -L #{proxy_arg} #{Shellwords.escape(url)}"
  full_command = "#{curl_cmd} | #{tool_cmd} #{renderer_args} -" 

  stdout, status = Open3.capture2(full_command)

  if status.success?
    return stdout.lines.map(&:chomp).reject(&:empty?)
  else
    return ["*** Ошибка рендеринга обложки (#{tool_cmd}) ***"]
  end
end

def update_time_data
    if $time_data[:status] == 'Playing' && $time_data[:start_time]
        elapsed = Time.now - $time_data[:start_time]
        new_current = $time_data[:offset] + elapsed
        
        $time_data[:current] = [new_current, $time_data[:total]].min
        
        if $time_data[:current] >= $time_data[:total] && $time_data[:total] > 0
             $time_data[:status] = 'Finished'
             return true
        end
    end
    return false
end

def volume_up
    if PLAYER == 'mplayer'
        # Команда MPlayer: "volume +10"
        system("echo 'volume +10' > #{FIFO_PATH} &")
        $current_volume = [$current_volume + 10, 200].min
    end
end

def volume_down
    if PLAYER == 'mplayer'
        system("echo 'volume -10' > #{FIFO_PATH} &")
        $current_volume = [$current_volume - 10, 0].max
    end
end

def rewind_forward
    if $time_data[:status] != 'Finished' && $player_pid && PLAYER == 'mplayer'
        system("echo 'seek +10 0' > #{FIFO_PATH} &") 
        $time_data[:current] = [$time_data[:current] + REWIND_STEP_SECONDS, $time_data[:total]].min
        $time_data[:offset] = $time_data[:current]
        $time_data[:start_time] = Time.now if $time_data[:status] == 'Playing'
    end
end

def rewind_backward
    if $time_data[:status] != 'Finished' && $player_pid && PLAYER == 'mplayer'
        system("echo 'seek -10 0' > #{FIFO_PATH} &")
        $time_data[:current] = [$time_data[:current] - REWIND_STEP_SECONDS, 0.0].max
        $time_data[:offset] = $time_data[:current]
        $time_data[:start_time] = Time.now if $time_data[:status] == 'Playing'
    end
end

def restart_player
    nil
end



def redraw_window(win, player)
    max_height = Curses.lines
    max_width  = Curses.cols
    height = max_height
    width  = max_width
    
    return if height < 5 || width < 30

    win.resize(height, width) 
    win.move(0, 0) 
    win.clear
    win.box(0, 0)
    
    if $playlist_tracks.empty?
        win.setpos(height / 2 - 3, (width / 2) - 30)
        win.addstr("Плейлист пуст. Используйте клавишу '/' для поиска.")
        win.setpos(height / 2 - 2, (width / 2) - 20)
        win.addstr("Нажмите 'Q' для выхода.")
    else
        cover_height = $ascii_cover.size
        content_start_row = (height / 2) - ((cover_height + 13) / 2) 
        current_row = [2, content_start_row].max 
        
        if cover_height > 0
            cover_width = $ascii_cover.map(&:length).max || 0
            col_cover = (width / 2) - (cover_width / 2)
            
            $ascii_cover.each do |line|
                win.setpos(current_row, col_cover)
                win.addstr(line)
                current_row += 1
            end
            current_row += 1 
        end
        
        playing_str = "🎵 Playing:"
        col_playing = (width / 2) - (playing_str.length / 2)
        win.setpos(current_row, col_playing)
        win.addstr(playing_str) 
        current_row += 1
        
        playlist_position_str = "[#{$current_track_index + 1}/#{$playlist_tracks.size}]"
        col_position = (width / 2) - (playlist_position_str.length / 2)
        win.setpos(current_row, col_position)
        win.addstr(playlist_position_str) 
        current_row += 1


        display_title = $track_title
        max_title_length = width - 4 
        if display_title.length > max_title_length
            display_title = display_title[0, max_title_length - 3] + "..."
        end
        col_title = (width / 2) - (display_title.length / 2)
        win.setpos(current_row, col_title)
        win.addstr(display_title) 
        current_row += 2 

        vol_str = "(Vol: #{$current_volume}%)" 
        status_str = "Status: Playing (Player: #{player}) #{vol_str}"
        col_status = (width / 2) - (status_str.length / 2)
        win.setpos(current_row, col_status)
        win.addstr(status_str) 
        current_row += 2 

        current_time_f = $time_data[:current].to_f.round(0)
        total_time_f = $time_data[:total].to_i
        current_time = format_time(current_time_f)
        total_time = format_time(total_time_f)
        time_str = "#{current_time} / #{total_time}"
        col_time = (width / 2) - (time_str.length / 2)
        win.setpos(current_row, col_time)
        win.addstr(time_str)
        current_row += 1

        progress_bar_width = [50, width - 10].min 
        if total_time_f > 0
            progress = $time_data[:current] / total_time_f
        else
            progress = 0
        end
        
        progress_bar_width_max = [progress_bar_width, 1].max 
        
        filled_width = (progress * progress_bar_width_max).to_i
        filled_width = [0, [filled_width, progress_bar_width_max].min].max
        
        progress_char = '█' 
        progress_line = "[#{progress_char * filled_width}#{' ' * (progress_bar_width_max - filled_width)}]"
        
        col_progress = (width / 2) - (progress_bar_width_max / 2) - 1 
        win.setpos(current_row, col_progress)
        win.addstr(progress_line)
        current_row += 2
    end
    
    instruction_str = "Q: Exit | /: Search | P/SPACE: Pause | R/F: Rewind | N/B: Track | +/-: Volume"
    col_instruction = (width / 2) - (instruction_str.length / 2)
    win.setpos(height - 2, col_instruction)
    win.addstr(instruction_str) 
end

def start_drawing_thread(win, player)
  Thread.new do
    loop do
      break if $time_data[:status] == 'Finished' || $time_data[:status] == 'Exiting'

      track_finished = update_time_data
      break if track_finished
      
      Curses.resizeterm(0, 0) rescue nil
      win.touch
      redraw_window(win, player)
      win.refresh 
      Curses.doupdate
      
      sleep(TUI_UPDATE_INTERVAL_MS.to_f / 1000)
    end
  end
end

def play_track_cycle
    
    temp_file_path = get_temp_file_path

    def download_track(original_url, path) 
        
        proxy = ENV['ALL_PROXY']
        env_opts = proxy ? {"ALL_PROXY" => proxy} : {}
        
        yt_dlp_command = [
            "yt-dlp", 
            "--no-warnings", 
            "-o", 
            path, 
            Shellwords.escape(original_url)
        ]

        puts "\n⏬ Скачивание трека в: #{path}..."
        puts "   > Команда: yt-dlp (ALL_PROXY=SOCKS5_PROXY_HIDDEN)"

        stdout, stderr, status = Open3.capture3(env_opts, *yt_dlp_command)
        
        unless status.success?
            puts "❌ Ошибка скачивания! (yt-dlp код: #{status.exitstatus})"
            puts stderr
            return false
        end
        puts "✅ Скачивание завершено."
        return true
    end

    def start_player(start_position_seconds, file_path)
        $playback_state[:start_position] = start_position_seconds
        
        cmd = get_player_command(file_path) 

        options = { 
            :in => :close, 
            :out => '/dev/null', 
            :err => '/dev/null', 
            :close_others => true 
        } 
        
        Process.kill('TERM', $player_pid) rescue nil
        $player_pid = Process.spawn(*cmd, options)
        
        $time_data[:start_time] = Time.now
        $time_data[:offset] = $playback_state[:start_position]
        $time_data[:status] = 'Playing' 
        if $playback_state[:start_position] > 0
             sleep(0.5)
             system("echo 'seek #{$playback_state[:start_position]} 2' > #{FIFO_PATH} &") # 2 - абсолютная перемотка
        end
    end
    
    # 1. Скачивание 
    unless File.exist?(temp_file_path)
        unless download_track($stream_url, temp_file_path) 
            return :NEXT 
        end

        puts "⌛ Ожидание готовности файла перед запуском #{PLAYER}..."
        sleep 1 
        wait_start = Time.now
        
        loop do
            if File.exist?(temp_file_path) && File.size(temp_file_path) > 0
                puts "✅ Файл готов."
                break
            end

            if Time.now - wait_start > 15
                puts "❌ Ошибка: Файл не стал доступен в течение 15 секунд. Пропуск трека."
                return :NEXT
            end
            sleep 0.1
        end
    end

    start_player($playback_state[:start_position], temp_file_path)

    $drawing_thread = start_drawing_thread($curses_win, PLAYER)
    
begin
        loop do

            player_finished = Process.waitpid($player_pid, Process::WNOHANG) rescue nil if $player_pid
            
            if $playlist_tracks.empty?
                 $time_data[:status] = 'Ready (Search /)'
            elsif player_finished || $time_data[:status] == 'Finished'
                $playlist_action ||= :NEXT 
                break
            end

            key = $curses_win.getch
            
            unless key.nil?
                case key
                when 'q', 'Q'
                    $playlist_action = :EXIT
                    break
                when '/' 
                    $playlist_action = :SEARCH
                    break
                when 'n', 'N' 
                    $playlist_action = :NEXT
                    break
                when 'b', 'B' 
                    $playlist_action = :PREVIOUS
                    break
                when 'p', 'P', ' '
                    if $player_pid && PLAYER == 'mplayer'
                        system("echo 'pause' > #{FIFO_PATH} &")
                        if $time_data[:status] == 'Playing'
                            $time_data[:status] = 'Paused'
                            $time_data[:offset] = $time_data[:current] 
                            $time_data[:start_time] = nil 
                        elsif $time_data[:status] == 'Paused'
                            $time_data[:status] = 'Playing'
                            $time_data[:start_time] = Time.now 
                        end
                    end
                when 'r', 'R'
                    rewind_backward
                when 'f', 'F'
                    rewind_forward
                when '+', '=' 
                    volume_up
                when '-'
                    volume_down
                end
            end 
            
            sleep(0.01) 
        end

    rescue Interrupt
        $playlist_action = :EXIT
    ensure
        $drawing_thread.kill if $drawing_thread.alive? rescue nil

        Process.kill('TERM', $player_pid) rescue nil if $player_pid

        if File.exist?(temp_file_path)
            FileUtils.rm_f(temp_file_path)
            puts "\n🗑️ Удален временный файл: #{temp_file_path}"
        end
        if File.exist?(FIFO_PATH)
            FileUtils.rm_f(FIFO_PATH)
            puts "🗑️ Удален управляющий FIFO: #{FIFO_PATH}"
        end

        action = $playlist_action
        $playlist_action = nil 
        return action
    end
end


def interactive_search_cli
    puts "\n🎶 Интерактивный поиск SoundCloud"
    print "Введите поисковый запрос (или Q для отмены): "
    search_query = STDIN.gets.chomp
    
    return nil if ['q', 'Q', 'quit', 'exit'].include?(search_query.downcase)
    
    search_url = "scsearch10:#{search_query}"
    search_command = [
        "yt-dlp", 
        "--flat-playlist", 
        "--dump-single-json", 
        "--no-warnings", 
        Shellwords.escape(search_url)
    ]
    
    puts "Searching for tracks..."
    
    proxy = ENV['ALL_PROXY']
    env_opts = proxy ? {"ALL_PROXY" => proxy} : {}

    stdout, _, status = Open3.capture3(env_opts, *search_command)
    
    unless status.success?
        puts "❌ Ошибка при выполнении поиска через yt-dlp."
        return nil
    end
    
    begin
        search_result = JSON.parse(stdout.lines.last.strip)
    rescue JSON::ParserError
        puts "❌ Ошибка парсинга результата поиска. Попробуйте другой запрос."
        return nil
    end

    entries = search_result['entries']
    if entries.nil? || entries.empty?
        puts "🤷‍♂️ Ничего не найдено по запросу: '#{search_query}'."
        return nil
    end
    
    puts "\n🔍 Найдено #{entries.size} треков. Выберите номер трека:"
    
    entries.each_with_index do |entry, index|
        title = entry['title'] || "Unknown Title"
        uploader = entry['uploader'] || "Unknown Artist"
        display_title = "#{uploader} - #{title}"
        display_title = display_title[0, 80] + "..." if display_title.length > 80
        puts "#{index + 1}. #{display_title}"
    end
    
    print "\nВведите номер (1-#{entries.size}) или Q для отмены: "
    choice = STDIN.gets.chomp.downcase
    
    return nil if ['q', 'quit', 'exit'].include?(choice)
    
    choice_index = choice.to_i - 1
    
    if choice_index >= 0 && choice_index < entries.size
        return entries[choice_index]
    else
        puts "Неверный номер. Отмена выбора."
        return nil
    end
end

def play_playlist
    Curses.init_screen
    Curses.noecho
    Curses.curs_set(0)
    Curses.timeout = 0 
    $curses_win = Curses::Window.new(0, 0, 0, 0) 

    begin
        loop do
            
            if $playlist_tracks.empty?
                $stream_url = nil
                $track_title = "Use '/' to Search..."
                $time_data[:total] = 0
                $current_track_index = 0
                $ascii_cover = []
                
                action = play_track_cycle 
            else
                if $current_track_index >= $playlist_tracks.size
                    $playlist_action = :EXIT
                    break 
                end
                
                current_track = $playlist_tracks[$current_track_index]
                
                $stream_url = current_track[:stream_url]
                $track_title = current_track[:track_title]
                $time_data = {
                  current: 0.0, 
                  total: current_track[:total_duration] || 0, 
                  status: 'Loading',
                  start_time: nil,    
                  offset: 0.0         
                }
                $playback_state[:start_position] = 0.0
                
                puts "\n🖼️ Загрузка и рендеринг обложки..."
                $ascii_cover = get_ascii_cover_output(current_track[:thumbnail_url], 40)
                puts "✅ Обложка загружена."
                
                action = play_track_cycle 
            end

            if action == :EXIT
                break 
            elsif action == :PREVIOUS
                $current_track_index = [$current_track_index - 1, 0].max
                $time_data[:status] = 'Loading' 
            elsif action == :NEXT
                $current_track_index += 1
                $time_data[:status] = 'Loading'
            elsif action == :SEARCH
                Curses.close_screen 
                
                selected_entry = interactive_search_cli
                
                if selected_entry
                    track_data = get_track_data_recursive(selected_entry)
                    if track_data.is_a?(Array)
                        track_data.each { |item| $playlist_tracks << item }
                    elsif track_data
                        insert_index = $playlist_tracks.empty? ? 0 : $current_track_index + 1
                        $playlist_tracks.insert(insert_index, track_data)
                        $current_track_index = insert_index
                        puts "✅ Трек добавлен и будет воспроизведен следующим."
                    end
                end
                
                Curses.init_screen
                Curses.noecho
                Curses.curs_set(0)
                Curses.timeout = 0
                $curses_win = Curses::Window.new(0, 0, 0, 0)
                
                next 
            end

        end
    rescue Interrupt
        nil
    ensure
        Curses.close_screen if Curses.stdscr 
        puts "\n⏹️ Воспроизведение плейлиста завершено."
    end
end

def main
  unless system('which mplayer > /dev/null 2>&1')
     puts "❌ Ошибка: MPlayer не найден. Пожалуйста, установите MPlayer (например, sudo apt install mplayer)."
     exit 1
  end

  track_urls = ARGV
  
  if track_urls.empty?
    puts "--------------------------------------------------------"
    puts "🎶 CLIFY Player: Режим интерактивного запуска"
    puts "--------------------------------------------------------"

    selected_entry = interactive_search_cli 
    
    if selected_entry
      track_data = get_track_data_recursive(selected_entry)
      
      if track_data.is_a?(Array)
          track_data.each { |item| $playlist_tracks << item }
      elsif track_data
        $playlist_tracks << track_data
      end
    end
    
    if $playlist_tracks.empty?
      puts "\nReady to run TUI. Use '/' key to search and add tracks."
    else
      puts "\nReady to play #{$playlist_tracks.size} tracks in total. Starting playback..."
    end
    
  else
    puts "Scanning #{track_urls.size} URLs..."

    track_urls.each_with_index do |url, index|
      puts "Processing URL #{index + 1}/#{track_urls.size}: #{url}"
      
      track_data = get_track_data_recursive(url)
      
      if track_data.is_a?(Array)
          track_data.each { |item| $playlist_tracks << item }
          puts "✅ Successfully added #{track_data.size} tracks from playlist."
      elsif track_data
        $playlist_tracks << track_data
        puts "✅ Successfully added single track."
      else
        puts "Skipping URL #{index + 1} due to error or no playable content found."
      end
    end
  end
  
  play_playlist
end

main
