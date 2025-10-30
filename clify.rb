#!/usr/bin/env ruby
# encoding: utf-8

require 'open3'
require 'curses'
require 'shellwords'
require 'json'
require 'thread' 
require 'time' 

# --- КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
TUI_UPDATE_INTERVAL_MS = 100 
PLAYER = 'ffplay' 
REWIND_STEP_SECONDS = 10 

# Глобальные объекты для потоков и Curses
$player_pid = nil
$curses_win = nil
$drawing_thread = nil

# Глобальные данные о текущем треке
$track_title = "Loading..."
$stream_url = nil
$ascii_cover = [] 

# Глобальное состояние плейлиста
$playlist_tracks = [] 
$current_track_index = 0
$playlist_action = nil 

# Управление состоянием
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

# Внешний контроль громкости 
$current_volume = 100 
$restart_required = false 

def get_proxy_argument
    proxy = ENV['ALL_PROXY']
    return proxy ? "--proxy #{Shellwords.escape(proxy)}" : ""
end

# --- ФУНКЦИИ МЕТАДАННЫХ ---

def extract_metadata(data)
    stream_url = data['url'] || data['formats']&.last&.[]('url') 
    
    return nil unless stream_url 

    artist = data['artist'] || data['uploader'] || "Unknown Artist"
    title = data['title'] || "Unknown Title"
    track_title = "#{artist} - #{title}"
    total_duration = data['duration'].to_i if data['duration']
    thumbnail_url = data['thumbnail']

    { 
      stream_url: stream_url, 
      track_title: track_title, 
      total_duration: total_duration,
      thumbnail_url: thumbnail_url
    }
end

# --- 1. ФУНКЦИЯ ПОЛУЧЕНИЯ ДАННЫХ О ТРЕКЕ ---

def get_track_data_recursive(track_or_entry)
  
  proxy_arg = get_proxy_argument 
  
  if track_or_entry.is_a?(Hash)
    url = track_or_entry['webpage_url'] || track_or_entry['url']
    is_playlist_item = true
  else
    url = track_or_entry
    is_playlist_item = false
  end
  
  return nil unless url

  # --- ПОПЫТКА ОБРАБОТКИ КАК ПЛЕЙЛИСТ ---
  unless is_playlist_item
    puts "Checking for playlist/set: #{url}..."
    
    playlist_command = "yt-dlp --flat-playlist --dump-single-json --no-warnings #{proxy_arg} #{Shellwords.escape(url)}"
    
    stdout, _, status = Open3.capture3(playlist_command)
    
    if status.success?
      begin
        playlist_json = JSON.parse(stdout.lines.last.strip)
        
        if playlist_json['_type'] == 'playlist' && playlist_json['entries'].is_a?(Array)
          
          playlist_items = []
          puts "Playlist detected with #{playlist_json['entries'].size} entries. Processing items..."
          
          playlist_json['entries'].each do |entry|
            # Рекурсивный вызов для обработки элемента
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

  # --- ПОПЫТКА ОБРАБОТКИ КАК ОДИНОЧНЫЙ ТРЕК ---
  
  puts "Waiting for stream data (single track): #{url}..."
  
  command = "yt-dlp -f bestaudio/best --dump-json --no-warnings --no-playlist #{proxy_arg} #{Shellwords.escape(url)}"
  
  stdout, stderr, status = Open3.capture3(command)
  
  unless status.success?
    puts "❌ Error while getting data from yt-dlp for single track:" unless is_playlist_item
    puts stderr unless is_playlist_item
    return nil
  end
  
  begin
    data = JSON.parse(stdout)
    return extract_metadata(data)
    
  rescue JSON::ParserError => e
    puts "❌ Error JSON parsing from yt-dlp. Maybe, yt-dlp did not find a playable stream. Error: #{e.message}" unless is_playlist_item
    return nil
  end
end

# --- 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ВРЕМЕНИ И КОМАНДЫ ---

def format_time(seconds)
  return '0:00' if seconds.nil? || seconds.to_i < 0
  seconds = seconds.to_i
  minutes = seconds / 60
  secs = seconds % 60
  "#{minutes}:#{'%02d' % secs}"
end

def get_ffplay_command
    args = "-nodisp -autoexit -loglevel error -probesize 32 -analyzeduration 10000000"
    ss_arg = $playback_state[:start_position] > 0 ? "-ss #{$playback_state[:start_position].round(2)}" : ""
    player_command = "#{PLAYER} #{args} #{ss_arg} -i #{Shellwords.escape($stream_url)}"
    return Shellwords.split(player_command)
end

# --- 2.5. ФУНКЦИЯ ПОЛУЧЕНИЯ ASCII-АРТА ---

def get_ascii_cover_output(url, width)
  proxy_arg = ""
  
  if proxy = ENV['ALL_PROXY']
      # Curl использует -x для прокси
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

# --- 2.7. ФУНКЦИЯ ОБНОВЛЕНИЯ ВРЕМЕНИ ---
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

# --- 2.8. ЛОГИКА УПРАВЛЕНИЯ ---

def restart_player
    $restart_required = true
end

def rewind_forward
    if $time_data[:status] != 'Finished'
        new_pos = $time_data[:current] + REWIND_STEP_SECONDS
        $playback_state[:start_position] = [new_pos, $time_data[:total]].min
        
        $time_data[:offset] = $playback_state[:start_position]
        $time_data[:current] = $playback_state[:start_position]
        $time_data[:start_time] = Time.now if $time_data[:status] == 'Playing'
        
        restart_player
    end
end

def rewind_backward
    if $time_data[:status] != 'Finished'
        new_pos = $time_data[:current] - REWIND_STEP_SECONDS
        $playback_state[:start_position] = [new_pos, 0.0].max
        
        $time_data[:offset] = $playback_state[:start_position]
        $time_data[:current] = $playback_state[:start_position]
        $time_data[:start_time] = Time.now if $time_data[:status] == 'Playing'
        
        restart_player
    end
end

def volume_up
    if system('which pactl > /dev/null 2>&1')
        system("pactl set-sink-volume @DEFAULT_SINK@ +10%")
        $current_volume = [$current_volume + 10, 200].min 
    elsif system('which amixer > /dev/null 2>&1')
        system("amixer -D pulse set Master 10%+")
        $current_volume = [$current_volume + 10, 200].min 
    else
        $current_volume = [$current_volume + 10, 200].min 
    end
end

def volume_down
    if system('which pactl > /dev/null 2>&1')
        system("pactl set-sink-volume @DEFAULT_SINK@ -10%")
        $current_volume = [$current_volume - 10, 0].max
    elsif system('which amixer > /dev/null 2>&1')
        system("amixer -D pulse set Master 10%-")
        $current_volume = [$current_volume - 10, 0].max
    else
        $current_volume = [$current_volume - 10, 0].max
    end
end


# --- 3. ФУНКЦИЯ ОТРИСОВКИ TUI ---

def redraw_window(win, player)
    max_height = Curses.lines
    max_width  = Curses.cols
    height = max_height
    width  = max_width
    
    return if height < 5 || width < 30

    cover_height = $ascii_cover.size

    win.resize(height, width) 
    win.move(0, 0) 
    win.clear
    win.box(0, 0)
    
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
    status_str = "Status: #{$time_data[:status]} (Player: #{player}) #{vol_str}"
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
    
    filled_width = (progress * progress_bar_width).to_i
    filled_width = [0, [filled_width, progress_bar_width].min].max
    
    progress_char = '█' 
    progress_line = "[#{progress_char * filled_width}#{' ' * (progress_bar_width - filled_width)}]"
    
    col_progress = (width / 2) - (progress_bar_width / 2) - 1 
    win.setpos(current_row, col_progress)
    win.addstr(progress_line)
    current_row += 2
    
    instruction_str = "Q: Exit | P/SPACE: Pause | R/F: Rewind (10s) | N/B: Track | +/-: Volume"
    col_instruction = (width / 2) - (instruction_str.length / 2)
    win.setpos(height - 2, col_instruction)
    win.addstr(instruction_str) 
end

# --- 4. ПОТОК ДЛЯ РЕГУЛЯРНОЙ ОТРИСОВКИ ---
def start_drawing_thread(win, player)
  Thread.new do
    loop do
      break if $time_data[:status] == 'Finished' || $time_data[:status] == 'Exiting'

      track_finished = update_time_data
      break if track_finished
      
      Curses.resizeterm(0, 0)
      win.touch
      redraw_window(win, player)
      win.refresh 
      Curses.doupdate
      
      sleep(TUI_UPDATE_INTERVAL_MS.to_f / 1000)
    end
    Process.kill('TERM', $player_pid) rescue nil if $player_pid
  end
end


# --- 5. ЦИКЛ ВОСПРОИЗВЕДЕНИЯ ОДНОГО ТРЕКА ---

def play_track_cycle
    def start_ffplay(start_position_seconds)
        $playback_state[:start_position] = start_position_seconds
        cmd = get_ffplay_command
        
        options = { :in => :close, :out => '/dev/null', 2 => '/dev/null', :close_others => true }
        
        Process.kill('TERM', $player_pid) rescue nil if $player_pid
        $player_pid = spawn(*cmd, options)
        
        $time_data[:start_time] = Time.now
        $time_data[:offset] = $playback_state[:start_position]
        $time_data[:status] = 'Playing'
    end
    
    start_ffplay($playback_state[:start_position])

    $drawing_thread = start_drawing_thread($curses_win, PLAYER)
    
begin
        loop do
            
            if $restart_required
                current_time = $time_data[:current]
                start_ffplay(current_time) 
                $restart_required = false
            end
            
            player_finished = Process.waitpid($player_pid, Process::WNOHANG) rescue nil
            
            if player_finished || $time_data[:status] == 'Finished'
                $playlist_action ||= :NEXT 
                break
            end
            
            key = $curses_win.getch
            
            unless key.nil?
                case key
                when 'q', 'Q'
                    $playlist_action = :EXIT
                    break
                when 'n', 'N' 
                    $playlist_action = :NEXT
                    break
                when 'b', 'B' 
                    $playlist_action = :PREVIOUS
                    break
                when 'p', 'P', ' '
                    if $time_data[:status] == 'Playing'
                        Process.kill('SIGSTOP', $player_pid)
                        $time_data[:status] = 'Paused'
                        $time_data[:offset] = $time_data[:current] 
                        $time_data[:start_time] = nil 
                    elsif $time_data[:status] == 'Paused'
                        Process.kill('SIGCONT', $player_pid)
                        $time_data[:status] = 'Playing'
                        $time_data[:start_time] = Time.now 
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
        begin
            if $player_pid && Process.kill(0, $player_pid) 
                Process.kill('TERM', $player_pid)
            end
        rescue Errno::ESRCH
        end
        
        action = $playlist_action
        $playlist_action = nil 
        return action
    end
end


# --- 6. ОСНОВНОЙ ЦИКЛ ПЛЕЙЛИСТА ---

def play_playlist
    Curses.init_screen
    Curses.noecho
    Curses.curs_set(0)
    Curses.timeout = 0 
    $curses_win = Curses::Window.new(0, 0, 0, 0) 

    begin
        while $current_track_index < $playlist_tracks.size
            
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
            
            puts "\n🖼️ Предварительный рендеринг обложки для трека №#{$current_track_index + 1}..."
            $ascii_cover = get_ascii_cover_output(current_track[:thumbnail_url], 40)
            puts "✅ Обложка загружена. Запуск плеера."

            action = play_track_cycle 
            
            if action == :EXIT
                break 
            elsif action == :PREVIOUS
                $current_track_index = [$current_track_index - 1, 0].max
            elsif action == :NEXT
                $current_track_index += 1
            end

        end
    rescue Interrupt
        nil
    ensure
        Curses.close_screen if Curses.stdscr 
        puts "\n⏹️ Воспроизведение плейлиста завершено."
    end
end

# --- НОВАЯ ФУНКЦИЯ ---

def search_and_select_track
    puts "\n🎶 Режим поиска SoundCloud"
    print "Введите поисковый запрос (или Q для выхода): "
    search_query = STDIN.gets.chomp
    
    return nil if ['q', 'Q', 'quit', 'exit'].include?(search_query.downcase)
    
    search_url = "scsearch10:#{search_query}"
    proxy_arg = get_proxy_argument
    
    search_command = "yt-dlp --flat-playlist --dump-single-json --no-warnings #{proxy_arg} #{Shellwords.escape(search_url)}"
    
    puts "Searching for tracks..."
    stdout, _, status = Open3.capture3(search_command)
    
    unless status.success?
        puts "❌ Ошибка при выполнении поиска через yt-dlp."
        return nil
    end
    
    begin
        # Берем последнюю строку 
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


# --- 7. ОСНОВНАЯ ФУНКЦИЯ ---

def main
  track_urls = ARGV
  
  if track_urls.empty?
    # Режим: Поиск
    selected_entry = search_and_select_track
    
    unless selected_entry
        puts "No track selected. Exiting."
        exit 0
    end
    
    track_data = get_track_data_recursive(selected_entry)
    
    if track_data.is_a?(Array)
        track_data.each { |item| $playlist_tracks << item }
        puts "✅ Successfully added #{track_data.size} tracks from search."
    elsif track_data
      $playlist_tracks << track_data
      puts "✅ Successfully added selected track."
    else
      puts "Skipping track due to error or no playable content found."
    end
    
  else
    # Режим: URL-аргументы
    puts "Scanning #{track_urls.size} URLs..."

    track_urls.each_with_index do |url, index|
      puts "Processing URL #{index + 1}/#{track_urls.size}: #{url}"
      
      track_data = get_track_data_recursive(url)
      
      if track_data.is_a?(Array)
          track_data.each do |item|
               $playlist_tracks << item
          end
          puts "✅ Successfully added #{track_data.size} tracks from playlist."
      elsif track_data
        $playlist_tracks << track_data
        puts "✅ Successfully added single track."
      else
        puts "Skipping URL #{index + 1} due to error or no playable content found."
      end
    end
  end
  
  if $playlist_tracks.empty?
    puts "Error: No playable tracks found in the arguments provided."
    exit 1
  end
  
  puts "\nReady to play #{$playlist_tracks.size} tracks in total. Starting playback..."

  play_playlist
end

main
