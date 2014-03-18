import core.thread;
import std.stdio;
import std.socket;
import std.json;
import std.string;
import std.algorithm;
import std.conv;
import std.file;
import std.array;

class CommandHandler : core.thread.Thread {
  import std.regex, std.algorithm, std.range, std.stdio;
  Socket conn;
  this(Socket connection) {
    conn = connection;
    super(&run);
  }

  string getNick(string prefix) {
    return prefix.split("!")[0];
  }

  void handleCommand(string prefix, string type, string destination, string message) {
    switch(type) {
      case "PING":
        conn.send("PONG " ~ message);
        break;
      case "PRIVMSG":
        writefln("<%s> %s\n", getNick(prefix), message);
        break;
      default:
    }
  }

  void handleString(string s) {
    foreach(command; s.split("\r\n")) {
      auto result = match(command, `^(?:[:](\S+) )?(\S+)(?: (?!:)(.+?))?(?: [:](.+))?$`);

      foreach(line; result) {
        string prefix = line.captures[1];
        string type = line.captures[2];
        string destination = line.captures[3];
        string message = line.captures[4];
        handleCommand(prefix, type, destination, message);
      }
    }
  }

  void run() {
    while(true) {
      char[8192] buffer;
      auto received = conn.receive(buffer);
      string s = buffer[0.. received].idup;
      handleString(s);
    }
  }
}

Socket connectToServer(string host, ushort port) {
  Socket conn = new TcpSocket();
  conn.connect(new InternetAddress(host.dup, port));

  return conn;
}

struct Config {
  string server;
  ushort port;
  string nick;
  string[] channels;
}

Config readConfigFile(string filename) {
  auto content = filename.readText;
  JSONValue cfg = parseJSON(content)["config"];
  string server = cfg["server"].str;
  auto port = to!ushort(cfg["port"].integer);
  string nick = cfg["nick"].str;
  string[] channels = array(cfg["channels"].array.map!(a => to!string(a.str))); // whoa!!

  return Config(server, port, nick, channels);
}

void setNick(Socket conn, string nick) {
  writeln("Set nick to " ~ nick);
  conn.send("nick " ~ nick ~ "\r\n");
}

void joinChannel(Socket conn, string channel) {
  writeln("Joined channel " ~ channel);
  conn.send("join " ~ channel ~ "\r\n");
}

void main() {
  auto config = readConfigFile("config.json");
  Socket conn = connectToServer(config.server, config.port);
  conn.send("user dirc 0 * :DIRC IRC Bot\r\n");

  setNick(conn, config.nick);
  CommandHandler ch = new CommandHandler(conn);
  ch.start();

  foreach(channel; config.channels)
    joinChannel(conn, channel);
}

