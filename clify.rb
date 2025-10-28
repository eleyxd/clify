#!/usr/bin/env ruby
# encoding: utf-8

require 'open3'
require 'curses'
require 'shellwords'
require 'json'

# --- КОНСТАНТЫ ---
PLAYER = 'ffplay' 
PLAYER_ARGS = {
  # Добавляем -nostdin, чтобы ffplay не блокировал ввод Curses.
  'ffplay' => '-nodisp -autoexit'
}

# --- 1. ФУНКЦИЯ ПОЛУЧЕНИЯ ДАННЫХ О ТРЕКЕ ---

def get_track_data(track_url)
  puts "Waiting for stream data: #{track_url}..."
  # Добавляем -f bestaudio/best для более надежного URL SoundCloud
  command = "yt-dlp -f bestaudio/best --skip-download --print-json --no-playlist --no-warnings #{Shellwords.escape(track_url)}"
  stdout, stderr, status = Open3.capture3(command)
  
  unless status.success?
    puts "Error while getting data from yt-dlp:"
    puts stderr
    return nil
  end
  puts "DEBUG: stdout (first 200): #{stdout[0,200]}"
  
  begin
    data = JSON.parse(stdout)
    # ИСПРАВЛЕНИЕ: Используем || вместо пробела
    stream_url = data['url'] || data['formats']&.first&.[]('url')
    artist = data['artist'] || data['uploader'] || "Unknown Artist"
    title = data['title'] || "Unknown title"
    track_title = "#{artist} - #{title}"
    
    return { stream_url: stream_url, track_title: track_title }
    
  rescue JSON::ParserError
    puts "Error JSON parsing from yt-dlp. Maybe, yt-dlp doest find track"
    return nil
  end
end

# --- 2. ВСПОМОГАТЕЛЬНАЯ ФУНКЦИЯ ДЛЯ ОТРИСОВКИ TUI (ДИНАМИЧЕСКАЯ) ---

def redraw_window(win, track_title, player)
    # Получаем размеры консоли
    max_height = Curses.lines
    max_width  = Curses.cols
    
    # Вычисляем размеры окна (95% ширины, минимум 10 строк)
    height = [10, max_height].min 
    width  = (max_width * 0.95).to_i
    
    # Центрируем окно
    start_row = (max_height - height) / 2
    start_col = (max_width - width) / 2
    
    # Изменяем размер и перемещаем окно (move вместо mvwin)
    win.resize(height, width) 
    win.move(start_row, start_col) 
    
    # Перерисовываем содержимое
    win.clear
    # win.box() без аргументов использует стандартные символы
    win.box(0, 0)
    
    # Адаптивное обрезание текста
    max_title_length = width - 5 
    display_title = track_title
    if display_title.length > max_title_length
        display_title = display_title[0, max_title_length - 3] + "..."
    end

    # Вывод информации
    win.setpos(2, 2)
    win.addstr("🎵 PLAYING") 
    win.setpos(3, 2)
    win.addstr(display_title) 

    win.setpos(5, 2)
    win.addstr("Player: #{player}") 

    win.setpos(7, 2)
    win.addstr("Press Q or Ctrl+C to exit...") 
    
    win.refresh 
    Curses.doupdate
end

# --- 3. ФУНКЦИЯ ВОСПРОИЗВЕДЕНИЯ (С УПРАВЛЕНИЕМ) ---

def play_stream(stream_url, player, track_title)
    # Инициализация переменных вне begin для ensure
    win = nil 
    pid = nil

    unless player
      puts "Error: ffplay was not found."
      return
    end

    args = PLAYER_ARGS[player]
    player_command = "#{player} #{args} #{Shellwords.escape(stream_url)}"
    
    # Разбиваем команду на массив аргументов для Kernel#spawn
    cmd = Shellwords.split(player_command)
    
    begin
        # --- 1. ИНИЦИАЛИЗАЦИЯ Curses ПЕРЕД ЗАПУСКОМ ПЛЕЕРА ---
        # Это решает проблему "окно сразу закрывается"
        Curses.init_screen
        Curses.noecho
        Curses.curs_set(0)
        Curses.stdscr.keypad(true)
        Curses.timeout = 100 # Неблокирующий ввод
        
        win = Curses::Window.new(0, 0, 0, 0) 
        
        # Обработчик SIGWINCH для динамического размера
        Signal.trap('WINCH') do
            Curses.stdscr.resize(0, 0)
            redraw_window(win, track_title, player)
        end
        
        # Изначальная отрисовка
        redraw_window(win, track_title, player)
        
        # --- 2. ЗАПУСК ПЛЕЕРА В ФОНОВОМ РЕЖИМЕ (Kernel#spawn) ---
        # :out и :err перенаправляются в /dev/null, чтобы избежать конфликта с Curses
        # :pgroup => true создает новую группу процессов, чтобы избежать конфликтов сигналов
        pid = spawn(*cmd, :out => '/dev/null', :err => '/dev/null', :pgroup => true)
        
        # --- 3. ГЛАВНЫЙ ЦИКЛ УПРАВЛЕНИЯ ---
        loop do
            # ПРОВЕРКА ЖИЗНИ ПРОЦЕССА
            begin
                # Process.waitpid вернет PID, если процесс завершился.
                break unless Process.waitpid(pid, Process::WNOHANG).nil?
            rescue Errno::ECHILD
                break # Процесс уже мертв и собран.
            end
            
            key = Curses.getch
            
            case key
            when 'q', 'Q'
                # Убиваем процесс, используя PID
                Process.kill('TERM', pid)
                break
            end
            
            # Перерисовываем регулярно
            redraw_window(win, track_title, player)
        end

    rescue Interrupt
        nil
    ensure
        # --- 4. ФИНАЛЬНАЯ ОЧИСТКА ---
        
        # Убиваем плеер (с обработкой Errno::ESRCH)
        begin
            # Проверяем, жив ли процесс, перед попыткой убить (Process.kill(0, pid))
            if pid && Process.kill(0, pid) 
                Process.kill('TERM', pid)
            end
        rescue Errno::ESRCH
        end
        
        Curses.close_screen if Curses.stdscr 
        puts "\n⏹️ Воспроизведение завершено."
    end
end

# --- 4. ОСНОВНАЯ ФУНКЦИЯ ---

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
    
    play_stream(stream_url, PLAYER, track_title)
  else
    puts "Error: no stream url"
  end
end

main
