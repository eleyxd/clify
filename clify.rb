require 'shellwords'
require 'open3'
PLAYER = ['ffplay'].find { |p| system("which #{p} < /dev/null 2>&1")}
PLAYER_ARGS = {
  'ffplay' => '-nodisp -autoexit'
}
def get_url(track_url)
  puts "Waiting for stream: #{track_url}..."
  command = "yt-dlp -g --skip-download #{Shellwords.escape(track_url)}"
  stdout, stderr, status = Open3.capture3(command)
  
  unless status.success?
    puts "Error while getting URL from yt-dlp:"
    puts stderr
    return nil
  end
  stream_url = stdout.lines.first.strip
  if stream_url.empty?
    puts "Error: yt-dlp doesnt return url"
    return nil
  end
  return stream_url
end

def play_stream(stream_url,player)
  puts "Starting player (#{player})..."
  puts "\n Press Ctrl+C for end of streaming"

  args=PLAYER_ARGS[player]
  player_command = "#{player} #{args} #{Shellwords.escape(stream_url)}"
  system(player_command)
  puts "Streaming is completed"

  rescue Interrupt
  puts "\n Streaming is interrupted by user"
end

def main
  unless PLAYER 
    puts "Error: CLI player not founded"
    puts "Please, install 'ffplay' (from 'FFMpeg' package) or 'mpg123'."
    exit 1
  end
  track_url = ARGV[0]
  if track_url.nil? || track_url.empty?
    puts "Using: #{$0} <URL track from the any site>"
    exit 1
  end
  stream_url=get_url(track_url)

  if stream_url
    play_stream(stream_url, PLAYER)
  end
end

main

