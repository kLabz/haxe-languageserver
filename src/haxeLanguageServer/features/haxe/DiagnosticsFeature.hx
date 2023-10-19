package haxeLanguageServer.features.haxe;

import haxe.Json;
import haxe.display.JsonModuleTypes;
import haxe.ds.BalancedTree;
import haxe.io.Path;
import haxeLanguageServer.LanguageServerMethods;
import haxeLanguageServer.helper.PathHelper;
import haxeLanguageServer.helper.Set;
import haxeLanguageServer.protocol.DisplayPrinter;
import haxeLanguageServer.server.DisplayResult;
import js.Node.clearImmediate;
import js.Node.setImmediate;
import js.node.ChildProcess;
import jsonrpc.CancellationToken;
import languageServerProtocol.Types.Diagnostic;
import languageServerProtocol.Types.DiagnosticRelatedInformation;
import languageServerProtocol.Types.DiagnosticSeverity;
import languageServerProtocol.Types.Location;

using Lambda;

class DiagnosticsFeature {
	public static inline final SortImportsUsingsTitle = "Sort imports/usings";
	public static inline final OrganizeImportsUsingsTitle = "Organize imports/usings";
	public static inline final RemoveUnusedImportUsingTitle = "Remove unused import/using";
	public static inline final RemoveAllUnusedImportsUsingsTitle = "Remove all unused imports/usings";
	public static inline final FixAllTitle = "Fix All";

	final context:Context;
	final diagnosticsArguments:Map<DocumentUri, DiagnosticsMap<Any>>;
	final pendingRequests:Map<DocumentUri, CancellationTokenSource>;
	final errorUri:DocumentUri;

	var haxelibPath:Null<FsPath>;

	public function new(context:Context) {
		this.context = context;
		diagnosticsArguments = new Map();
		pendingRequests = new Map();
		errorUri = new FsPath(Path.join([context.workspacePath.toString(), "Error"])).toUri();

		ChildProcess.exec(context.config.haxelib.executable + " config", (error, stdout, stderr) -> haxelibPath = new FsPath(stdout.trim()));

		context.languageServerProtocol.onNotification(LanguageServerMethods.RunGlobalDiagnostics, onRunGlobalDiagnostics);
	}

	function onRunGlobalDiagnostics(_) {
		final stopProgress = context.startProgress("Collecting Diagnostics");
		final onResolve = context.startTimer("@diagnostics");

		context.callDisplay("global diagnostics", ["diagnostics"], null, null, function(result) {
			processDiagnosticsReply(null, onResolve, result);
			context.languageServerProtocol.sendNotification(LanguageServerMethods.DidRunRunGlobalDiagnostics);
			stopProgress();
		}, function(error) {
			processErrorReply(null, error);
			stopProgress();
		});
	}

	function processErrorReply(uri:Null<DocumentUri>, error:String) {
		if (!extractDiagnosticsFromHaxeError(uri, error) && !extractDiagnosticsFromHaxeError2(error)) {
			if (uri != null) {
				clearDiagnosticsOnClient(uri);
			}
			clearDiagnosticsOnClient(errorUri);
		}
		trace(error);
	}

	function extractDiagnosticsFromHaxeError(uri:Null<DocumentUri>, error:String):Bool {
		final problemMatcher = ~/(.+):(\d+): (?:lines \d+-(\d+)|character(?:s (\d+)-| )(\d+)) : (?:(Warning) : )?(.*)/;
		if (!problemMatcher.match(error))
			return false;

		var file = problemMatcher.matched(1);
		if (!Path.isAbsolute(file))
			file = Path.join([Sys.getCwd(), file]);

		final targetUri = new FsPath(file).toUri();
		if (targetUri != uri)
			return false; // only allow error reply diagnostics in current file for now (clearing becomes annoying otherwise...)

		if (isPathFiltered(targetUri.toFsPath()))
			return false;

		inline function getInt(i)
			return Std.parseInt(problemMatcher.matched(i));

		final line = getInt(2);
		var endLine = getInt(3);
		final column = getInt(4);
		final endColumn = getInt(5);
		if (line == null) {
			return false;
		}

		function makePosition(line:Int, character:Null<Int>) {
			return {
				line: line - 1,
				character: if (character == null) 0 else context.displayOffsetConverter.positionCharToZeroBasedColumn(character)
			}
		}

		if (endLine == null)
			endLine = line;
		final position = makePosition(line, column);
		final endPosition = makePosition(endLine, endColumn);

		final diag = {
			range: {start: position, end: endPosition},
			severity: DiagnosticSeverity.Error,
			message: problemMatcher.matched(7)
		};
		publishDiagnostic(targetUri, diag, error);
		return true;
	}

	function extractDiagnosticsFromHaxeError2(error:String):Bool {
		final problemMatcher = ~/^(Error): (.*)$/;
		if (!problemMatcher.match(error)) {
			return false;
		}
		final diag = {
			range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}},
			severity: DiagnosticSeverity.Error,
			message: problemMatcher.matched(2)
		};
		publishDiagnostic(errorUri, diag, error);
		return true;
	}

	function publishDiagnostic(uri:DocumentUri, diag:Diagnostic, error:String) {
		context.languageServerProtocol.sendNotification(PublishDiagnosticsNotification.type, {uri: uri, diagnostics: [diag]});
		final argumentsMap = diagnosticsArguments[uri] = new DiagnosticsMap();
		argumentsMap.set({code: CompilerError, range: diag.range}, error);
	}

	function processDiagnosticsReply(uri:Null<DocumentUri>, onResolve:(result:Dynamic, ?debugInfo:String) -> Void, result:DisplayResult) {
		clearDiagnosticsOnClient(errorUri);
		final data:Array<HaxeDiagnosticResponse<Any>> = switch result {
			case DResult(s):
				try {
					Json.parse(s);
				} catch (e) {
					trace("Error parsing diagnostics response: " + e);
					return;
				}
			case DCancelled:
				return;
		}
		var count = 0;
		final sent = new Map<DocumentUri, Bool>();
		for (data in data) {
			count += data.diagnostics.length;

			var file = data.file;
			if (file == null) {
				// LSP always needs a URI for now (https://github.com/Microsoft/language-server-protocol/issues/256)
				file = errorUri.toFsPath();
			}
			if (isPathFiltered(file))
				continue;

			final uri = file.toUri();
			final argumentsMap = diagnosticsArguments[uri] = new DiagnosticsMap();
			final doc = context.documents.getHaxe(uri);

			final newDiagnostics = filterRelevantDiagnostics(data.diagnostics);
			final diagnostics = new Array<Diagnostic>();
			for (hxDiag in newDiagnostics) {
				for (d in hxDiag.toDiagnostics(context, doc)) {
					argumentsMap.set({code: hxDiag.kind, range: d.range}, hxDiag.args);
					diagnostics.push(d);
				}
			}
			context.languageServerProtocol.sendNotification(PublishDiagnosticsNotification.type, {uri: uri, diagnostics: diagnostics});
			sent[uri] = true;
		}

		inline function removeOldDiagnostics(uri:DocumentUri) {
			if (!sent.exists(uri))
				clearDiagnosticsOnClient(uri);
		}

		if (uri == null) {
			for (uri in diagnosticsArguments.keys())
				removeOldDiagnostics(uri);
		} else {
			removeOldDiagnostics(uri);
		}

		onResolve(data, count + " diagnostics");
	}

	function isPathFiltered(path:FsPath):Bool {
		final pathFilter = PathHelper.preparePathFilter(context.config.user.diagnosticsPathFilter, haxelibPath, context.workspacePath);
		return !PathHelper.matches(path, pathFilter);
	}

	function filterRelevantDiagnostics(diagnostics:Array<HaxeDiagnostic<Any>>):Array<HaxeDiagnostic<Any>> {
		// hide regular compiler errors while there's parser errors, they can be misleading
		final hasProblematicParserErrors = diagnostics.find(d -> switch (d.kind : Int) {
			case ParserError: d.args != "Missing ;"; // don't be too strict
			case _: false;
		}) != null;
		if (hasProblematicParserErrors) {
			diagnostics = diagnostics.filter(d -> switch (d.kind : Int) {
				case CompilerError, UnresolvedIdentifier: false;
				case _: true;
			});
		}

		// hide unused import warnings while there's compiler errors (to avoid false positives)
		final hasCompilerErrors = diagnostics.find(d -> d.kind == cast CompilerError) != null;
		if (hasCompilerErrors) {
			diagnostics = diagnostics.filter(d -> d.kind != cast UnusedImport);
		}

		// hide inactive blocks that are contained within other inactive blocks
		diagnostics = diagnostics.filter(a -> a.kind != (cast InactiveBlock)
			|| !diagnostics.exists(b -> a != b && a.range != null && b.range != null && b.range.contains(a.range)));

		return diagnostics;
	}

	public function clearDiagnostics(uri:DocumentUri) {
		cancelPendingRequest(uri);
		clearDiagnosticsOnClient(uri);
	}

	function clearDiagnosticsOnClient(uri:DocumentUri) {
		if (diagnosticsArguments.remove(uri)) {
			context.languageServerProtocol.sendNotification(PublishDiagnosticsNotification.type, {uri: uri, diagnostics: []});
		}
	}

	public function publishDiagnostics(uri:DocumentUri) {
		if (!uri.isFile() || isPathFiltered(uri.toFsPath())) {
			clearDiagnosticsOnClient(uri);
			return;
		}
		cancelPendingRequest(uri);
		var tokenSource = new CancellationTokenSource();
		// we delay the actual request because in some cases `clearDiagnostics` will be called right away,
		// and since diagnostics call is rather expensive, we don't want to make redundant invokations
		// one scenario where this happens is vscode document preview, see https://github.com/microsoft/vscode/issues/78453
		var immediate = setImmediate(invokePendingRequest, uri, tokenSource.token);
		tokenSource.token.setCallback(clearImmediate.bind(immediate)); // will be re-set by callDisplay later
		pendingRequests[uri] = tokenSource;
	}

	function invokePendingRequest(uri:DocumentUri, token:CancellationToken) {
		final doc:Null<HaxeDocument> = context.documents.getHaxe(uri);
		if (doc != null) {
			final onResolve = context.startTimer("@diagnostics");
			context.callDisplay("@diagnostics", [doc.uri.toFsPath() + "@0@diagnostics"], null, token, result -> {
				pendingRequests.remove(uri);
				processDiagnosticsReply(uri, onResolve, result);
			}, error -> {
				pendingRequests.remove(uri);
				processErrorReply(uri, error);
			});
		} else {
			pendingRequests.remove(uri);
		}
	}

	function cancelPendingRequest(uri:DocumentUri) {
		var tokenSource = pendingRequests[uri];
		if (tokenSource != null) {
			pendingRequests.remove(uri);
			tokenSource.cancel();
		}
	}

	public function getArguments<T>(uri:DocumentUri, kind:DiagnosticKind<T>, range:Range):Null<T> {
		final map = diagnosticsArguments[uri];
		@:nullSafety(Off) // ?
		return if (map == null) null else map.get({code: kind, range: range});
	}

	public function getArgumentsMap(uri:DocumentUri):Null<DiagnosticsMap<Any>> {
		return diagnosticsArguments[uri];
	}
}

enum abstract UnresolvedIdentifierSuggestion(Int) {
	final Import;
	final Typo;
}

enum abstract MissingFieldCauseKind<T>(String) {
	final AbstractParent:MissingFieldCauseKind<{parent:JsonTypePathWithParams}>;
	final ImplementedInterface:MissingFieldCauseKind<{parent:JsonTypePathWithParams}>;
	final PropertyAccessor:MissingFieldCauseKind<{property:JsonClassField, isGetter:Bool}>;
	final FieldAccess:MissingFieldCauseKind<{}>;
	final StaticFieldAccess:MissingFieldCauseKind<{}>;
	final FinalFields:MissingFieldCauseKind<{fields:Array<JsonClassField>}>;
}

typedef MissingFieldCause<T> = {
	var kind:MissingFieldCauseKind<T>;
	var args:T;
}

typedef MissingField = {
	var field:JsonClassField;
	var type:JsonType<Dynamic>;

	/**
		When implementing multiple interfaces, there can be field duplicates among them. This flag is only
		true for the first such occurrence of a field, so that the "Implement all" code action doesn't end
		up implementing the same field multiple times.
	**/
	var unique:Bool;
}

typedef MissingFieldDiagnostic = {
	var fields:Array<MissingField>;
	var cause:MissingFieldCause<Dynamic>;
}

typedef MissingFieldDiagnostics = {
	var moduleType:JsonModuleType<Dynamic>;
	var moduleFile:String;
	var entries:Array<MissingFieldDiagnostic>;
}

private typedef HaxeDiagnosticData<T> = {
	final kind:DiagnosticKind<T>;
	final ?range:Range;
	final ?code:String;
	final severity:DiagnosticSeverity;
	final args:T;
	final relatedInformation:Null<Array<HaxeDiagnosticRelatedInformation>>;
}

@:forward
abstract HaxeDiagnostic<T>(HaxeDiagnosticData<T>) from HaxeDiagnosticData<T> to HaxeDiagnosticData<T> {
	// TODO: update code actions too!
		public function toDiagnostics(context:Context, doc:HaxeDocument):Array<Diagnostic> {
		function getRange() {
			if (this.range != null) return context.displayOffsetConverter.byteRangeToCharacterRange(this.range, doc);

			// range is not optional in the LSP yet
			return {
				start: {line: 0, character: 0},
				end: {line: 0, character: 0}
			};
		}

		final kind:Int = this.kind;
		final range = getRange();
		final printer = new DisplayPrinter(Never);

		function makeDiag(message:String, ?relatedInformation:Array<DiagnosticRelatedInformation>):Diagnostic {
			return {
				range: range,
				code: this.code,
				severity: this.severity,
				message: message,
				data: {kind: kind},
				relatedInformation: relatedInformation ?? this.relatedInformation?.map(rel -> {
					location: {
						uri: rel.location.file.toUri(),
						range: rel.location.range,
					},
					message: convertIndentation(rel.message, rel.depth)
				})
			};
		}

		return switch (this.kind : DiagnosticKind<T>) {
			case MissingFields:
				final causes = {
					fields: new Set<String>(),
					interfaces: new Set<String>(),
					statics: new Set<String>(),
					moduleFields: new Set<String>(),
					properties: new Set<String>(),
					misc: new Set<{msg:String, ?relatedInformation:Array<DiagnosticRelatedInformation>}>()
				};

				final args:MissingFieldDiagnostics = this.args;
				args.entries.iter(diag -> switch (diag.cause.kind) {
					case AbstractParent: causes.fields.add(printer.printPathWithParams(diag.cause.args.parent)); // TODO: check that one
					case ImplementedInterface: causes.interfaces.add(printer.printPathWithParams(diag.cause.args.parent));
					case PropertyAccessor: causes.properties.add(diag.cause.args.property.name);

					// Haxe 4.3.3+
					case StaticFieldAccess:
						switch (args.moduleType.kind) {
							case Class:
								switch (args.moduleType.args.kind.kind) {
									case KModuleFields:
										final ckind:JsonClassKind<JsonModulePath> = args.moduleType.args.kind;
										causes.moduleFields.add(ckind.args.moduleName);
									case _: causes.statics.add(args.moduleType.name);
								}
							case _: causes.statics.add(args.moduleType.name);
						}

					case FieldAccess:
						switch (args.moduleType.kind) {
							case Class:
								switch (args.moduleType.args.kind.kind) {
									case KAbstractImpl:
										final ckind:JsonClassKind<JsonTypePath> = args.moduleType.args.kind;
										causes.statics.add(ckind.args.typeName);
									case _: causes.fields.add(args.moduleType.name);
								}

							// TODO special case in actions too
							case _ if (args.moduleType.name == "Void"): causes.misc.add({msg: 'Type Void has no fields'});
							case _: causes.fields.add(args.moduleType.name);
						}

					case FinalFields:
						final fields:Array<JsonClassField> = diag.cause.args.fields;
						final relatedInformation = [];
						for (f in fields) {
							relatedInformation.push({
								location: {
									// TODO: fix file
									// file: new FsPath(f.pos.file),
									uri: doc.uri,
									// TODO converter
									range: doc.rangeAt(f.pos.min, f.pos.max)
									// range: {
									// 	// TODO
									// 	start: {line: 0, character: 0},
									// 	end: {line: 0, character: 0}
									// }
								},
								message: "Uninitialized final field"
							});
						}
						causes.misc.add({
							msg: 'Missing constructor for ${args.moduleType.name} (uninitialized final fields)',
							relatedInformation: relatedInformation
						});
				});

				final diags = [];

				final interfaces = Lambda.array(causes.interfaces);
				if (interfaces.length > 0) diags.push(makeDiag('Missing fields for interface${interfaces.length > 0 ? "s" : ""} ${interfaces.join(", ")}'));

				// Can't have more than one on same diagnostic?
				// final properties = Lambda.array(causes.properties);
				// if (properties.length > 0) diags.push(makeDiag('Missing fields for propertie${properties.length > 0 ? "s" : ""} ${properties.join(", ")}'));

				for (cause in causes.fields) diags.push(makeDiag('Missing field for $cause'));
				for (cause in causes.properties) diags.push(makeDiag('Missing fields for property $cause'));
				for (cause in causes.statics) diags.push(makeDiag('Missing static field for $cause'));
				for (cause in causes.moduleFields) diags.push(makeDiag('Missing module level field for $cause'));
				for (cause in causes.misc) diags.push(makeDiag(cause.msg, cause.relatedInformation));

				diags;

			case _:
				final diag = makeDiag(this.kind.getMessage(doc, this.args, range));

				if (kind == RemovableCode || kind == UnusedImport || diag.message.contains("has no effect") || kind == InactiveBlock) {
					diag.severity = Hint;
					diag.tags = [Unnecessary];
				}
				if (diag.message == "This case is unused") {
					diag.tags = [Unnecessary];
				}
				if (kind == DeprecationWarning) {
					diag.tags = [Deprecated];
				}

				[diag];
		};

	}

	function convertIndentation(msg:String, depth:Int):String {
		if (msg.startsWith("... ")) {
			msg = msg.substr(4);
			depth++;
		}

		if (depth < 2)
			return msg;

		final buf = new StringBuf();
		for (_ in 1...depth)
			buf.add("⋅⋅⋅");
		buf.add(" ");
		buf.add(msg);
		return buf.toString();
	}
}

enum abstract DiagnosticKind<T>(Int) from Int to Int {
	final UnusedImport:DiagnosticKind<Void>;
	final UnresolvedIdentifier:DiagnosticKind<Array<{kind:UnresolvedIdentifierSuggestion, name:String}>>;
	final CompilerError:DiagnosticKind<String>;
	final RemovableCode:DiagnosticKind<{description:String, range:Range}>;
	final ParserError:DiagnosticKind<String>;
	final DeprecationWarning:DiagnosticKind<String>;
	final InactiveBlock:DiagnosticKind<Void>;
	final MissingFields:DiagnosticKind<MissingFieldDiagnostics>;

	public inline function new(i:Int) {
		this = i;
	}

	public function getMessage(doc:HaxeDocument, args:T, range:Range) {
		return switch (this : DiagnosticKind<T>) {
			case UnusedImport: "Unused import/using";
			case UnresolvedIdentifier:
				var message = 'Unknown identifier';
				if (doc != null) {
					message += ' : ${doc.getText(range)}';
				}
				message;
			case CompilerError: args.trim();
			case RemovableCode: args.description;
			case ParserError: args;
			case DeprecationWarning: args;
			case InactiveBlock: "Inactive conditional compilation block";
			case MissingFields: "Missing fields"; // Handled in HaxeDiagnostic.toDiagnostics()
		}
	}
}

private typedef HaxeDiagnosticRelatedInformation = {
	final location:{
		final file:FsPath;
		final range:Range;
	};
	final message:String;
	final depth:Int;
}

private typedef HaxeDiagnosticResponse<T> = {
	final ?file:FsPath;
	final diagnostics:Array<HaxeDiagnostic<T>>;
}

private typedef DiagnosticsMapKey = {code:Int, range:Range};

private class DiagnosticsMap<T> extends BalancedTree<DiagnosticsMapKey, T> {
	override function compare(k1:DiagnosticsMapKey, k2:DiagnosticsMapKey) {
		final start1 = k1.range.start;
		final start2 = k2.range.start;
		final end1 = k1.range.end;
		final end2 = k2.range.end;
		inline function compare(i1, i2, e) {
			return i1 < i2 ? -1 : i1 > i2 ? 1 : e;
		}
		return compare(k1.code, k2.code,
			compare(start1.line, start2.line,
				compare(start1.character, start2.character, compare(end1.line, end2.line, compare(end1.character, end2.character, 0)))));
	}
}
