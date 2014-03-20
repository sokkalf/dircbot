import core.thread;
import std.stdio;
import std.socket;
import std.json;
import std.string;
import std.algorithm;
import std.conv;
import std.file;
import std.array;
import std.concurrency;
import std.getopt;

extern (C) int fork ();

class CommandHandler : core.thread.Thread {
  import std.regex, std.algorithm, std.range, std.stdio;
  Socket conn;
  Tid mainTid;
  bool registered = false;
  bool isRegistering = false;
  Admin[string] admins;
  Admin[string] authenticatedAdmins;
  bool[string] channelsJoined;
  string nick;

  this(Socket connection, Tid tid) {
    conn = connection;
    mainTid = tid;
    super(&run);
  }

  void addAdmin(string username, string password) {
    verboseWrite("Adding admin : %s", username);
    admins[username] = Admin(username, password);
  }

  void addAuthenticatedAdmin(string ircUser, Admin admin) {
    authenticatedAdmins[ircUser] = admin;
  }

  bool authenticateAdmin(string ircUser, string username, string password) {
    Admin *admin = (username in admins);
    if(admin is null) return false;
    if(admin.password == password) {
      addAuthenticatedAdmin(ircUser, *admin);
      return true;
    } else return false;
  }

  bool isAuthenticated(string ircUser) {
    return ((ircUser in authenticatedAdmins) !is null);
  }

  string getNick(string prefix) {
    return prefix.split("!")[0];
  }

  void setRegistered(bool r) {
    registered = r;
    notifyRegistered();
  }

  void notifyRegistered() { // notify main thread that we are good to go.   
    send(mainTid, isRegistered);
    isRegistering = false;
  }

  void register() {
    isRegistering = true;
    conn.send("user dirc 0 * :DIRC IRC Bot\r\n");
  }

  void register(string password) {
    conn.send("pass " ~ password ~ "\r\n");
    register();
  }

  void setNick(string nick) {
    verboseWrite("Setting nick to " ~ nick);
    conn.send("nick " ~ nick ~ "\r\n");
    this.nick = nick;
  }

  void joinChannel(string channel) {
    if(isRegistered) {
      conn.send("join " ~ channel ~ "\r\n");
      channelsJoined[channel] = true;
    }
  }

  bool isInChannel(string channel) {
    return (((channel in channelsJoined) !is null) && (channelsJoined[channel] == true));
  }

  void sendMessage(string user, string message) {
    if(isRegistered) conn.send("privmsg " ~ user ~ " :" ~ message ~ "\r\n");
  }

  void changeMode(string user, string channel, string mode) {
    if(isRegistered) conn.send("mode " ~ channel ~ " " ~ mode ~ " " ~ user ~ "\r\n");
  }

  bool isRegistered() {
    return registered;
  }

  string getSrc(string message) {
    auto result = match(message, `(\S+)\s+(\S+)`);
    return result.captures[1];
  }

  string getDest(string message) {
    auto result = match(message, `(\S+)\s+(\S+)`);
    return result.captures[2];
  }

  void handleNumeric(string prefix, int numeric, string destination, string message) {
    switch(numeric) {
      case 001: // welcome
        setRegistered(true);
        break;
      case 403: // no such channel
        verboseWrite("Error joining channel %s : %s", getDest(destination), message);
        break;
      default:
    }
  }

  void handleUserCommand(string from, string command, string parameters) {
    switch(command.toUpper) {
      case "AUTH":
        auto result = match(parameters, `(\S+)\s+(\S+)`);
        string username = result.captures[1];
        string password = result.captures[2];
        if(authenticateAdmin(from, username, password))
          sendMessage(from, "Greetings, " ~ username ~ ", you are authenticated.");
        else
          sendMessage(from, "Authentication failed.");
        break;
      case "STATUS":
        if(isAuthenticated(from))
          sendMessage(from, "Hello " ~ from ~ ", you are authenticated as admin!");
        else
          sendMessage(from, "Bummer, no can do");
        break;
      case "OP":
        if(isAuthenticated(from)) {
          if(isInChannel(parameters)) { 
            changeMode(from, parameters, "+o");
          } else sendMessage(from, "I'm not in that channel!");
        } else sendMessage(from, "Not authorized.");
        break;
      default:  
    }
  }

  void handlePrivateMessage(string from, string message) {
    auto result = match(message, `(\S+)\s*(.*)`);
    string command = result.captures[1];
    string parameters = result.captures[2];

    handleUserCommand(from, command, parameters);
    debugWrite("Command %s, parameters %s", command, parameters);
  }

  void handleCommand(string prefix, string type, string destination, string message) {
    switch(type.toUpper) {
      case "PING":
        conn.send("PONG " ~ message);
        break;
      case "PRIVMSG":
        verboseWrite("<%s> %s\n", getNick(prefix), message);
        if(destination == nick) handlePrivateMessage(prefix, message);
        break;
      case "JOIN":
        if(getNick(prefix) == nick)
          verboseWrite("Joined channel %s", message);
        else verboseWrite("%s joined channel %s", getNick(prefix), message);
        break;
      case "PART":
        if(getNick(prefix) == nick)
          verboseWrite("Left channel %s", destination);
        else verboseWrite("%s left channel %s", getNick(prefix), destination);
        break;
      case "KICK":
        if(getDest(destination) == nick) {
          verboseWrite("Kicked from channel %s by %s", getSrc(destination), getNick(prefix));
          channelsJoined[getSrc(destination)] = false;
        } else verboseWrite("%s was kicked from channel %s by %s", getDest(destination), getSrc(destination), getNick(prefix));
        break;
      case "MODE":
        verboseWrite("Mode change %s - %s", destination, message);
        break;
      case "ERROR":
        if(isRegistering) {
          verboseWrite(message);
          setRegistered(false);
        }
        break;
      default:
        if(isNumeric(type))
          handleNumeric(prefix, to!int(type), destination, message);
    }
  }

  void handleString(string s) {
    foreach(command; s.split("\r\n")) {
      debugWrite(command);
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

// __gshared makes these reachable from the other thread
__gshared bool debugMode = false;
__gshared bool verbose = false;
__gshared bool daemon = false;
string configfile = "config.json";

void debugWrite(Char, A...)(in Char[] fmt, lazy A args) {
  if(debugMode)
    writefln(fmt, args);
}

void verboseWrite(Char, A...)(in Char[] fmt, lazy A args) {
  if(verbose)
    writefln(fmt, args);
}

Socket connectToServer(string host, ushort port) {
  Socket conn = new TcpSocket();
  conn.connect(new InternetAddress(host.dup, port));

  return conn;
}

struct Admin {
  string username;
  string password;
}

struct Config {
  string server;
  ushort port;
  string serverPassword;
  string nick;
  string[] channels;
  Admin[] admins;
}

Config readConfigFile(string filename) {
  // seems to crash with segfault if any of these fields are NOT present in config file..! :(
  auto content = filename.readText;

  JSONValue cfg = parseJSON(content)["config"];
  string server = cfg["server"].str;
  auto port = to!ushort(cfg["port"].integer);
  string serverPassword = cfg["password"].str;
  string nick = cfg["nick"].str;
  string[] channels = array(cfg["channels"].array.map!(a => to!string(a.str))); // whoa!!
  Admin[] admins;
  foreach(admin; cfg["admins"].array) {
    admins ~= Admin(admin["username"].str, admin["password"].str);
  }

  return Config(server, port, serverPassword, nick, channels, admins);
}

void main(string[] args) {
  getopt(args,
    "debug", &debugMode,
    "verbose", &verbose,
    "daemon", &daemon,
    "config", &configfile
  );

  if(daemon && debugMode) {
    debugWrite("Can't daemonize when debug mode is on.");
    daemon = false;
  }

  if(debugMode)
    verbose = true;

  if(daemon) {
    verbose = false;
    debugMode = false;
  }

  if(daemon)
    if(fork()) std.c.stdlib.exit(0); // into the background we go

  auto config = readConfigFile(configfile);
  Socket conn = connectToServer(config.server, config.port);
  CommandHandler ch = new CommandHandler(conn, thisTid);
  ch.start();
 
  foreach(admin; config.admins) {
    ch.addAdmin(admin.username, admin.password);
  }

  verboseWrite("Registering on IRC server " ~ config.server);
  // if password is not empty, register with password
  if(!config.serverPassword.empty)
    ch.register(config.serverPassword);
  else
    ch.register();

  ch.setNick(config.nick);
  bool registered = receiveOnly!(bool); // wait until registered flag is set

  if(registered) { 
    foreach(channel; config.channels)
      ch.joinChannel(channel);
  } else {
    verboseWrite("Error registering with IRC server!");
    std.c.stdlib.exit(1);
  }
}

