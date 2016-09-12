package common;

import jsonrpc.Protocol;
import languageServerProtocol.Types;

class HaxeTrace {
	static public function setup(protocol:Protocol) {
        haxe.Log.trace = function(v, ?i) {
            var r = [Std.string(v)];
            if (i != null && i.customParams != null) {
                for (v in i.customParams)
                    r.push(Std.string(v));
            }
            protocol.sendNotification(Methods.LogMessage, {type: Log, message: r.join(" ")});
        }
    }
}