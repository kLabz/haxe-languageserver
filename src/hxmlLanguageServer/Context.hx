package hxmlLanguageServer;

import jsonrpc.Types;
import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Protocol;
import languageServerProtocol.Types;
import common.TextDocuments;

class Context {
    public var workspacePath(default,null):String;
    public var protocol(default,null):Protocol;
	public var documents(default,null):TextDocuments;

    public function new(protocol) {
        this.protocol = protocol;
        protocol.onRequest(Methods.Initialize, onInitialize);
        protocol.onRequest(Methods.Shutdown, onShutdown);
		protocol.onNotification(Methods.DidOpenTextDocument, onDidOpenTextDocument);
	}

    function onInitialize(params:InitializeParams, token:CancellationToken, resolve:InitializeResult->Void, reject:ResponseError<InitializeError>->Void) {
        workspacePath = params.rootPath;
		documents = new TextDocuments(protocol);
		new hxmlLanguageServer.features.CompletionFeature(this);
        return resolve({
            capabilities: {
				textDocumentSync: TextDocuments.syncKind,
                completionProvider: {
                    triggerCharacters: [" ", ":"]
                },
                hoverProvider: true
            }
        });
    }

    function onShutdown(_, token:CancellationToken, resolve:NoData->Void, _) {
        return resolve(null);
    }

    @:access(common.TextDocuments.onDidOpenTextDocument)
    function onDidOpenTextDocument(event:DidOpenTextDocumentParams) {
        documents.onDidOpenTextDocument(event);
    }
}