require "rubygems"
require "bundler/setup"
require "json"
require "rest-client"
require "cinch"
require "thread"
require "yaml"

CONFIG = YAML.load_file(File.expand_path("config.yml"))
POOLS_FILE = File.expand_path("pools.yml")

LOCK = Mutex.new

def refresh_pools
  LOCK.synchronize do
    ctime = File.ctime(POOLS_FILE)

    if (@pools_ctime.nil? || (@pools_ctime != ctime))
      @pools = YAML.load_file(POOLS_FILE)
      @pools_ctime = ctime
    end
  end
end

def refresh_price
  LOCK.synchronize do
    @price ||= {}

    if (@last_price_update.nil? || (Time.now - @last_price_update > 180))
      resp = RestClient.get("https://bleutrade.com/api/v2/public/getticker?market=DCR_BTC")
      @price["Bleutrade"] = {}
      @price["Bleutrade"]["price"] = JSON.parse(resp)["result"][0]["Last"].to_f.round(8)
      @price["Bleutrade"]["vol"] = "?"

      @last_price_update = Time.now
    end
  end
end

def refresh_stats
  LOCK.synchronize do
    if (@last_stats_update.nil? || (Time.now - @last_stats_update > 60))
      url = "http://#{CONFIG["daemon"]["rpc_user"]}:#{CONFIG["daemon"]["rpc_password"]}@#{CONFIG["daemon"]["rpc_host"]}:#{CONFIG["daemon"]["rpc_port"]}"
      body = { "jsonrpc" => "2.0", "method" => "getmininginfo", "id" => 1 }
      resp = RestClient.post(url, body.to_json)
      @stats = JSON.parse(resp)["result"]

      @last_stats_update = Time.now
    end
  end
end

bot = Cinch::Bot.new do
  configure do |c|
    c.nick = CONFIG["nick"]
    c.password = CONFIG["password"]
    c.server = CONFIG["server"]
    c.channels = CONFIG["channels"]
  end

  on :message, "!help" do |m|
    m.user.msg "Commands: !pools, !worth <amount>, !price, !net, !calc <GH/s>"
  end

  on :message, "!pools" do |m|
    refresh_pools
    reply = "List of Bitmark (BTM) mining pools:\n\n"
    reply << @pools.shuffle.join("\n")
    m.user.msg reply
  end

  on :message, "!net" do |m|
    refresh_stats
    blocks = @stats["blocks"]
    diff = @stats["difficulty"]
    nethash = @stats["networkhashps"] / 1000000000.0
    m.user.msg "Diff: #{diff.round(8)}, Network: #{'%.4f' % nethash} GH/s, Blocks: #{blocks}"
  end

  on :message, "!price" do |m|
    refresh_price
    m.user.msg "Last: #{'%.8f' % @price["Bleutrade"]["price"]} BTC | Bleutrade | https://bleutrade.com"
  end

  on :message, /^!worth (\d+)/ do |m, amount|
    refresh_price
    total = amount.to_f * @price["Bleutrade"]["price"].to_f
    m.user.msg "#{amount} DCR = #{'%.8f' % total} BTC"
  end

  on :message, /^!calc (\d+)/ do |m, hashrate|
    refresh_stats
    diff = @stats["difficulty"]
    total = 1.0 / (diff * 2**32 / (hashrate.to_f * 1000000000) / 86400) * 18.717
    m.user.msg "With #{hashrate} GH/s you will mine ~#{'%.8f' % total} DCR per day"
  end
end

bot.start
