package haxeLanguageServer.features;

import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Types.NoData;
import languageServerProtocol.Types;
import haxeLanguageServer.helper.TypeHelper.prepareSignature;

class CompletionFeature {
    var context:Context;

    public function new(context) {
        this.context = context;
        context.protocol.onRequest(Methods.Completion, onCompletion);
    }

    function onCompletion(params:TextDocumentPositionParams, token:CancellationToken, resolve:Array<CompletionItem>->Void, reject:ResponseError<NoData>->Void) {
        var doc = context.documents.get(params.textDocument.uri);
        var r = calculateCompletionPosition(doc.content, doc.offsetAt(params.position));
        var bytePos = doc.offsetToByteOffset(r.pos);
        var args = ["--display", '${doc.fsPath}@$bytePos' + (if (r.toplevel) "@toplevel" else "")];
        context.callDisplay(args, doc.content, token, function(data) {
            if (token.canceled)
                return;

            var xml = try Xml.parse(data).firstElement() catch (_:Any) null;
            if (xml == null) return reject(ResponseError.internalError("Invalid xml data: " + data));

            var items = if (r.toplevel) parseToplevelCompletion(xml) else parseFieldCompletion(xml);
            resolve(items);
        }, function(error) reject(ResponseError.internalError(error)));
    }

    static var reFieldPart = ~/(\.|@)(\w*)$/;
    static function calculateCompletionPosition(text:String, index:Int):CompletionPosition {
        text = text.substring(0, index);
        if (reFieldPart.match(text))
            return {
                pos: index - reFieldPart.matched(2).length,
                toplevel: false,
            };
        else
            return {
                pos: index,
                toplevel: true,
            };
    }

    static function parseToplevelCompletion(x:Xml):Array<CompletionItem> {
        var result = [];
        for (el in x.elements()) {
            var kind = el.get("k");
            var type = el.get("t");
            var name = el.firstChild().nodeValue;

            var item:CompletionItem = {label: name};

            var displayKind = toplevelKindToCompletionItemKind(kind);
            if (displayKind != null) item.kind = displayKind;

            var fullName = name;
            if (kind == "global")
                fullName = el.get("p") + "." + name;
            else if (kind == "type")
                fullName = el.get("p");

            if (type != null || fullName != name) {
                var parts = [];
                if (fullName != name)
                    parts.push('($fullName)');
                if (type != null)
                    parts.push(type); // todo format functions?
                item.detail = parts.join(" ");
            }

            var doc = el.get("d");
            if (doc != null)
                item.documentation = doc;

            result.push(item);
        }
        return result;
    }

    static function toplevelKindToCompletionItemKind(kind:String):CompletionItemKind {
        return switch (kind) {
            case "local": Variable;
            case "member": Field;
            case "static": Class;
            case "enum" | "enumabstract": Enum;
            case "global": Variable;
            case "type": Class;
            case "package": Module;
            default: trace("unknown toplevel item kind: " + kind); null;
        }
    }


    static function parseFieldCompletion(x:Xml):Array<CompletionItem> {
        var result = [];
        for (el in x.elements()) {
            var rawKind = el.get("k");
            var kind = fieldKindToCompletionItemKind(rawKind);
            var type = null, doc = null;
            inline function getOrNull(s) return if (s == "") null else s;
            for (child in el.elements()) {
                switch (child.nodeName) {
                    case "t": type = getOrNull(child.firstChild().nodeValue);
                    case "d": doc = getOrNull(child.firstChild().nodeValue);
                }
            }
            var name = el.get("n");
            var isTimer = false;
            if (rawKind == "metadata") {
                name = name.substr(1); // remove @ for metas
            } else if (isTimerDebugFieldCompletion(name)) {
                kind = Value;
                name = name + " " + type;
                type = null;
                isTimer = true;
            }
            var item:CompletionItem = {label: name};
            if (doc != null) item.documentation = doc;
            if (kind != null) item.kind = kind;
            if (type != null) item.detail = formatType(type, name, kind);
            if (isTimer) item.insertText = " "; // can't be empty string or VSCode will ignore it, but still better than inserting this garbage 
            result.push(item);
        }
        return result;
    }

    static inline function isTimerDebugFieldCompletion(name:String):Bool {
        return name.startsWith("@TIME") || name.startsWith("@TOTAL");
    }

    static function formatType(type:String, name:String, kind:CompletionItemKind):String {
        return switch (kind) {
            case Method: name + prepareSignature(type);
            default: type;
        }
    }

    static function fieldKindToCompletionItemKind(kind:String):CompletionItemKind {
        return switch (kind) {
            case "var": Field;
            case "method": Method;
            case "type": Class;
            case "package": Module;
            case "metadata": Function;
            default: trace("unknown field item kind: " + kind); null;
        }
    }
}

private typedef CompletionPosition = {
    var pos:Int;
    var toplevel:Bool;
}
