package hxmlLanguageServer;

import js.Node.process;
import jsonrpc.node.MessageReader;
import jsonrpc.node.MessageWriter;
import jsonrpc.Protocol;
import languageServerProtocol.Types;

class Main {
    static function main() {
        var reader = new MessageReader(process.stdin);
        var writer = new MessageWriter(process.stdout);
        var protocol = new Protocol(writer.write);
        protocol.logError = function(message) protocol.sendNotification(Methods.LogMessage, {type: Warning, message: message});
        common.HaxeTrace.setup(protocol);
		new Context(protocol);
        reader.listen(protocol.handleMessage);
    }
}
