#!/usr/bin/env ruby
# encoding: utf-8

require 'open3'
require 'curses'
require 'shellwords'
require 'json'
require 'thread' 

# --- КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
TUI_UPDATE_INTERVAL_MS = 100 

PLAYER = 'ffplay' 

PLAYER_ARGS = {
  'ffplay' => '-nodisp -autoexit -loglevel error -probesize 32 -analyzeduration 10000000'
}

$time_data = {
  current: 0.0, 
  total: 0, 
  status: 'Playing'
}

# ФЛАГ ДЛЯ ОБРАБОТКИ ИЗМЕНЕНИЯ РАЗМЕРА ОКНА
$resized = false 

# --- 1. ФУНКЦИЯ ПОЛУЧЕНИЯ ДАННЫХ О ТРЕКЕ ---

def get_track_data(track_url)
  puts "Waiting for stream data: #{track_url}..."
  
  command = "yt-dlp -f bestaudio/best --dump-json --no-warnings --no-playlist #{Shellwords.escape(track_url)}"
  
  stdout, stderr, status = Open3.capture3(command)
  
  unless status.success?
    puts "❌ Error while getting data from yt-dlp:"
    puts stderr
    return nil
  end
  puts "DEBUG: stdout (first 200): #{stdout[0,200]}"
  
  begin
    data = JSON.parse(stdout)
    
    stream_url = data['url'] || data['formats']&.last&.[]('url') 
    
    artist = data['artist'] || data['uploader'] || "Unknown Artist"
    title = data['title'] || "Unknown Title"
    track_title = "#{artist} - #{title}"
    
    total_duration = data['duration'].to_i if data['duration']
    
    return { stream_url: stream_url, track_title: track_title, total_duration: total_duration }
    
  rescue JSON::ParserError
    puts "❌ Error JSON parsing from yt-dlp. Maybe, yt-dlp doest find track"
    return nil
  end
end

# --- 2. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ВРЕМЕНИ ---

def format_time(seconds)
  return '0:00' if seconds.nil? || seconds.to_i < 0
  seconds = seconds.to_i
  minutes = seconds / 60
  secs = seconds % 60
  "#{minutes}:#{'%02d' % secs}"
end

# --- 3. ФУНКЦИЯ ОТРИСОВКИ TUI ---

def redraw_window(win, track_title, player)
    # 1. Определение максимальных размеров 
    max_height = Curses.lines
    max_width  = Curses.cols
    
    # 2. Динамические размеры окна: привязка к краям 
    height = max_height
    width  = max_width
    start_row = 0
    start_col = 0
    

    return if height < 5 || width < 30

    # 3. Перерисовка, очистка и рамка (перезапуск окна)
    win.resize(height, width) 
    win.move(start_row, start_col) 
    win.clear
    win.box(0, 0) # Рамка теперь всегда по краям консоли
    
    # --- 4. ЦЕНТРИРОВАНИЕ СОДЕРЖИМОГО ---
    
    # Позиция начала контента (4 строки выше центра)
    content_start_row = (height / 2) - 4 
    
    display_title = track_title
    max_title_length = width - 4 
    if display_title.length > max_title_length
        display_title = display_title[0, max_title_length - 3] + "..."
    end
    
    # 4a. Заголовок "Playing"
    playing_str = "🎵 Playing:"
    col_playing = (width / 2) - (playing_str.length / 2)
    win.setpos(content_start_row, col_playing)
    win.addstr(playing_str) 

    # 4b. Название трека
    col_title = (width / 2) - (display_title.length / 2)
    win.setpos(content_start_row + 1, col_title)
    win.addstr(display_title) 

    # 4c. Статус и плеер
    status_str = "Status: #{$time_data[:status]} (Player: #{player})"
    col_status = (width / 2) - (status_str.length / 2)
    win.setpos(content_start_row + 3, col_status)
    win.addstr(status_str) 

    # --- 4d. ВРЕМЯ И ПРОГРЕСС-БАР ---
    
    current_time = format_time($time_data[:current])
    total_time = format_time($time_data[:total])
    
    # 4e. Время
    time_str = "#{current_time} / #{total_time}"
    col_time = (width / 2) - (time_str.length / 2)
    win.setpos(content_start_row + 5, col_time)
    win.addstr(time_str)

    # 4f. Прогресс-бар 
    progress_bar_width = [50, width - 10].min # Максимум 50 символов
    
    if $time_data[:total] > 0
        progress = $time_data[:current].to_f / $time_data[:total]
    else
        progress = 0
    end
    
    filled_width = (progress * progress_bar_width).to_i
    filled_width = [0, [filled_width, progress_bar_width].min].max
    
    progress_line = "[#{'█' * filled_width}#{' ' * (progress_bar_width - filled_width)}]"
    
    col_progress = (width / 2) - (progress_bar_width / 2) - 1 
    win.setpos(content_start_row + 6, col_progress)
    win.addstr(progress_line)
    
    # 4g. Инструкции
    instruction_str = "Press Q to exit, P or SPACE to pause/play..."
    col_instruction = (width / 2) - (instruction_str.length / 2)
    win.setpos(height - 2, col_instruction)
    win.addstr(instruction_str) 
    
    win.refresh 
    Curses.doupdate
end

# --- 4. ФУНКЦИЯ ВОСПРОИЗВЕДЕНИЯ ---

def play_stream(stream_url, player, track_title)
    win = nil 
    pid = nil
    serr_r = nil 
    player_error = nil 

    unless player
      puts "Error: ffplay was not found." 
      return
    end

    args = PLAYER_ARGS[player]
    player_command = "#{player} #{args} -i #{Shellwords.escape(stream_url)}"
    
    cmd = Shellwords.split(player_command)
    
begin
        # --- ИНИЦИАЛИЗАЦИЯ Curses ---
        Curses.init_screen
        Curses.noecho
        Curses.curs_set(0)
        Curses.timeout = TUI_UPDATE_INTERVAL_MS 
        
        win = Curses::Window.new(0, 0, 0, 0) 
        
        
        redraw_window(win, track_title, player)        
        # --- ЗАПУСК ПЛЕЕРА ---
        
        serr_r, serr_w = IO.pipe 
        
        pid = spawn(*cmd, {:in => :close, :out => '/dev/null', 2 => serr_w, :close_others => true})

        serr_w.close 
        
        # --- ГЛАВНЫЙ ЦИКЛ УПРАВЛЕНИЯ ---
          loop do
            if Curses.resizeterm(0, 0)

                Curses.clear
                Curses.refresh
                redraw_window(win, track_title, player)
            end
            
            if $time_data[:status] == 'Playing'
              $time_data[:current] += (TUI_UPDATE_INTERVAL_MS.to_f / 1000)
              
              if $time_data[:current] > $time_data[:total] && $time_data[:total] > 0
                  $time_data[:current] = $time_data[:total]
              end
            end
            
            player_status = Process.waitpid(pid, Process::WNOHANG)
            if player_status
                player_error = serr_r.read 
                break
            end
            
            key = Curses.getch
            
            case key
            when 'q', 'Q'
                Process.kill('TERM', pid) 
                break
            when 'p', 'P', ' '
                $time_data[:status] = ($time_data[:status] == 'Playing' ? 'Paused' : 'Playing')
            end
            
            redraw_window(win, track_title, player)
        end

    rescue Interrupt
        nil
    ensure
        
        begin
            serr_r.close if serr_r && !serr_r.closed?
            
            if pid && Process.kill(0, pid) 
                Process.kill('TERM', pid)
            end
        rescue Errno::ESRCH
        end
        
        Curses.close_screen if Curses.stdscr 
        
        if player_error && !player_error.empty?
            puts "\n❌ КРИТИЧЕСКАЯ ОШИБКА ПЛЕЕРА (ffplay STDERR):"
            puts player_error
        end
        
        puts "\n⏹️ Воспроизведение завершено."
    end
end

# --- 5. ОСНОВНАЯ ФУНКЦИЯ ---

def main
  track_url = ARGV[0]
  if track_url.nil? || track_url.empty?
    puts "Using: #{$0} <URL track from the any site>"
    exit 1
  end

  track_data = get_track_data(track_url)
  
  if track_data && track_data[:stream_url]
    stream_url = track_data[:stream_url]
    track_title = track_data[:track_title]
    
    $time_data[:total] = track_data[:total_duration] || 0
    
    play_stream(stream_url, PLAYER, track_title)
  else
    puts "Error: no stream url or metadata."
  end
end

main
