#!/usr/bin/env ruby
# encoding: utf-8
# # frozen_string_literal: true

require 'open3'
require 'curses'
require 'shellwords'
require 'json'


PLAYER = ['ffplay'].find { |p| system("which #{p} < /dev/null 2>&1")}
PLAYER_ARGS = {
  'ffplay' => '-nodisp -autoexit -loglevel quiet'
}
def get_track_data(track_url)
  puts "Waiting for stream data: #{track_url}..."
  command = "yt-dlp --skip-download --print-json --no-playlist --no-warnings #{Shellwords.escape(track_url)}"
  stdout, stderr, status = Open3.capture3(command)
  
  unless status.success?
    puts "Error while getting data from yt-dlp:"
    puts stderr
    return nil
  end
  puts "DEBUG: stdout (first 200): #{stdout[0,200]}"
  begin
    data = JSON.parse(stdout)
    stream_url = data ['url'] || data ['formats']&.first&.[]('url')
    artist = data['artist'] || data['uploader'] || "Unknown Artist"
    title = data['title'] || "Unknown title"
    track_title = "#{artist} - #{title}"
    return { stream_url: stream_url, track_title: track_title }
  rescue JSON::ParserError
    puts "Error JSON pasing from yt-dlp. Maybe, yt-dlp doest find track"
    return nil
  end

  stream_url = stdout.lines.first.strip
  if stream_url.empty?
    puts "Error: yt-dlp doesnt return url"
    return nil
  end
  return stream_url
end

def play_stream(stream_url, player, track_title)
  unless PLAYER
    Curses.addstr("Error: ffplay doenst founded")
    Curses.refresh
    return
  end
  begin
    Curses.init_screen
    Curses.noecho
    Curses.curs_set(0)
    height, width = 10, 50
    max_title_length = width - 5
    display_title = track_title
      if display_title.length > max_title_length
      display_title = display_title[0, max_title_length - 3] + "..."
    end 
    Curses.clear
    start_row, start_col = 2,2
    win = Curses::Window.new(height, width, start_row, start_col)
    win.box
    win.setpos(2,2)
    win.addstr("PLAYING")
    win.setpos(3,2)
    win.addstr(display_title)
    win.setpos(5,2)
    win.addstr("Player: #{PLAYER}")
    win.setpos(7,2)
    win.addstr("Press Ctrl+C to exit...")
    win.refresh

    args=PLAYER_ARGS[player]
    player_command = "#{player} #{args} #{Shellwords.escape(stream_url)}"
    system(player_command)

  rescue Interrupt
    nil
  ensure 
    Curses.close_screen
    puts "Streaming is completed"
  end 
end

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

