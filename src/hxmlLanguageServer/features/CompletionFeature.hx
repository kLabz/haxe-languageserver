package hxmlLanguageServer.features;

import jsonrpc.ResponseError;
import jsonrpc.CancellationToken;
import jsonrpc.Types;
import languageServerProtocol.Types;
import js.node.ChildProcess;

typedef HaxelibLib = {
    name: String,
    versions: Array<String>
}

typedef HaxelibDefine = {
    name: String,
    description: String
}

class CompletionFeature {
    var context:Context;
    var haxelibsMap:Map<String, HaxelibLib>;
    var haxelibs:Array<HaxelibLib>;
    var haxeDefinesMap:Map<String, HaxelibDefine>;
    var haxeDefines:Array<HaxelibDefine>;

    public function new(context) {
        this.context = context;
        haxelibs = [];
        haxelibsMap = new Map();
        haxeDefines = [];
        haxeDefinesMap = new Map();
        updateHaxelibs();
        updateHaxeDefines();
        context.protocol.onRequest(Methods.Completion, onCompletion);
        context.protocol.onRequest(Methods.Hover, onHover);
    }

    function updateHaxeDefines() {
        ChildProcess.exec("haxe --help-defines", function(error, stdout:String, stderr) {
            haxeDefinesMap = new Map();
            haxeDefines = [];
            var defines = stdout.split("\n");
            for (define in defines) {
                // awkward, but it's my own fault
                if (~/^  /.match(define)) {
                    haxeDefines[haxeDefines.length - 1].description += " " + define.trim();
                    continue;
                }
                define = define.trim();
                if (define == "") {
                    continue;
                }
                var split = define.split(":");
                var name = split.shift().trim();
                var define = {
                    name: name,
                    description: split.join(":").trim()
                };
                haxeDefinesMap[define.name] = define;
                haxeDefines.push(define);
            }
        });
    }

    function updateHaxelibs() {
        ChildProcess.exec("haxelib list", function(error, stdout:String, stderr) {
            var libs = stdout.split("\n");
            haxelibsMap = new Map();
            haxelibs = [];
            for (lib in libs) {
                lib = lib.trim();
                if (lib == "") {
                    continue;
                }
                var split = lib.split(":");
                var name = split.shift();
                var versionSplit = split.join(":").trim().split(" ");
                var versions = [];
                for (version in versionSplit) {
                    version = version.trim();
                    if (version == "") {
                        continue;
                    }
                    if (version.charAt(0) == "[") {
                        version = version.substr(1, version.length - 2);
                    }
                    if (version.charCodeAt(0) < "0".code || version.charCodeAt(0) > "9".code) {
                        continue;
                    }
                    versions.push(version);
                }
                var lib = {
                    name: name,
                    versions: versions
                }
                haxelibsMap[lib.name] = lib;
                haxelibs.push(lib);
            }
        });
    }

    function getLine(text:String, offset:Int) {
        var first = text.lastIndexOf("\n", offset - 1);
        var last = text.indexOf("\n", offset);
        if (first == -1) {
            first = 0;
        }
        if (last == -1) {
            last = text.length;
        }
        return text.substring(first, last).trim();
    }

	function onCompletion(params:TextDocumentPositionParams, token:CancellationToken, resolve:Array<CompletionItem>->Void, reject:ResponseError<NoData>->Void) {
        var doc = context.documents.get(params.textDocument.uri);
        var offset = doc.offsetAt(params.position);
        var line = getLine(doc.content, offset);
        switch (line) {
            case "-D":
                var result = [];
                for (define in haxeDefines) {
                    result.push({ label: define.name, documentation: define.description });
                }
                resolve(result);
            case "-lib":
                var result = [];
                for (lib in haxelibs) {
                    result.push({ label: lib.name, documentation: lib.versions.join(" ") });
                }
                resolve(result);
            case s:
                if (s.endsWith(":")) {
                    var split = s.split(":");
                    split = split[split.length - 2].split(" ");
                    var libName = split[split.length - 1];
                    if (haxelibsMap.exists(libName)) {
                        var result = [];
                        for (v in haxelibsMap[libName].versions) {
                            result.push({label: v});
                        }
                        resolve(result);
                    }
                }
        }
	}

    function onHover(params:TextDocumentPositionParams, token:CancellationToken, resolve:Hover->Void, reject:ResponseError<NoData>->Void) {
        var doc = context.documents.get(params.textDocument.uri);
        var offset = doc.offsetAt(params.position);
        var line = getLine(doc.content, offset);
        var split = line.split(" ");
        switch (split.shift()) {
            case "-D":
                var define = split.join(" ");
                if (haxeDefinesMap.exists(define)) {
                    if (!token.canceled) {
                        resolve({contents: haxeDefinesMap[define].description});
                    }
                }
        }
        reject(ResponseError.internalError("No information found"));
    }
}