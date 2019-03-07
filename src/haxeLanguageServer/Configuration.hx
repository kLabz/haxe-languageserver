package haxeLanguageServer;

import haxe.Json;
import jsonrpc.Protocol;
import haxe.extern.EitherType;
import haxeLanguageServer.helper.ImportHelper.ImportStyle;
import haxeLanguageServer.helper.FunctionFormattingConfig;
import haxeLanguageServer.helper.StructDefaultsMacro;

private typedef FunctionGenerationConfig = {
	var ?anonymous:FunctionFormattingConfig;
	var ?field:FunctionFormattingConfig;
}

private typedef ImportGenerationConfig = {
	var ?enableAutoImports:Bool;
	var ?style:ImportStyle;
}

private typedef CodeGenerationConfig = {
	var ?functions:FunctionGenerationConfig;
	var ?imports:ImportGenerationConfig;
}

private typedef UserConfig = {
	var ?enableCodeLens:Bool;
	var ?enableDiagnostics:Bool;
	var ?enableServerView:Bool;
	var ?enableSignatureHelpDocumentation:Bool;
	var ?diagnosticsPathFilter:String;
	var ?displayPort:EitherType<Int, String>;
	var ?buildCompletionCache:Bool;
	var ?codeGeneration:CodeGenerationConfig;
	var ?exclude:Array<String>;
}

private typedef InitOptions = {
	var ?displayServerConfig:DisplayServerConfig;
	var ?displayArguments:Array<String>;
	var ?sendMethodResults:Bool;
}

enum ConfigurationKind {
	User;
	DisplayArguments;
	DisplayServer;
}

class Configuration {
	final onDidChange:(kind:ConfigurationKind) -> Void;
	var unmodifiedUserConfig:UserConfig;

	public var user(default, null):UserConfig;
	public var displayServer(default, null):DisplayServerConfig;
	public var displayArguments(default, null):Array<String>;
	public var sendMethodResults(default, null):Bool = false;

	public function new(protocol:Protocol, onDidChange:(kind:ConfigurationKind) -> Void) {
		this.onDidChange = onDidChange;

		protocol.onNotification(Methods.DidChangeConfiguration, onDidChangeConfiguration);
		protocol.onNotification(LanguageServerMethods.DidChangeDisplayArguments, onDidChangeDisplayArguments);
		protocol.onNotification(LanguageServerMethods.DidChangeDisplayServerConfig, onDidChangeDisplayServerConfig);
	}

	public function onInitialize(params:InitializeParams) {
		var options:InitOptions = params.initializationOptions;
		var defaults:InitOptions = {
			displayServerConfig: {
				path: "haxe",
				env: new haxe.DynamicAccess(),
				arguments: [],
				print: {
					completion: false,
					reusing: false
				}
			},
			displayArguments: [],
			sendMethodResults: false
		};
		StructDefaultsMacro.applyDefaults(options, defaults);
		displayServer = options.displayServerConfig;
		displayArguments = options.displayArguments;
		sendMethodResults = options.sendMethodResults;
	}

	function onDidChangeConfiguration(newConfig:DidChangeConfigurationParams) {
		var initialized = user != null;
		var newHaxeConfig = newConfig.settings.haxe;
		if (newHaxeConfig == null) {
			newHaxeConfig = {};
		}

		var newConfigJson = Json.stringify(newHaxeConfig);
		var configUnchanged = Json.stringify(unmodifiedUserConfig) == newConfigJson;
		if (initialized && configUnchanged) {
			return;
		}
		unmodifiedUserConfig = Json.parse(newConfigJson);

		processSettings(newHaxeConfig);
		onDidChange(User);
	}

	function processSettings(newConfig:Dynamic) {
		// this is a hacky way to completely ignore uninteresting config sections
		// to do this properly, we need to make language server not watch the whole haxe.* section,
		// but only what's interesting for us
		Reflect.deleteField(newConfig, "displayServer");
		Reflect.deleteField(newConfig, "displayConfigurations");
		Reflect.deleteField(newConfig, "executable");

		user = newConfig;

		var defaults:UserConfig = {
			enableCodeLens: false,
			enableDiagnostics: true,
			enableServerView: false,
			enableSignatureHelpDocumentation: true,
			diagnosticsPathFilter: "${workspaceRoot}",
			displayPort: null,
			buildCompletionCache: true,
			codeGeneration: {
				functions: {
					anonymous: {
						returnTypeHint: Never,
						argumentTypeHints: false,
						useArrowSyntax: true,
						explicitNull: false,
					},
					field: {
						returnTypeHint: NonVoid,
						argumentTypeHints: true,
						placeOpenBraceOnNewLine: false,
						explicitPublic: false,
						explicitPrivate: false,
						explicitNull: false,
					}
				},
				imports: {
					style: Type,
					enableAutoImports: true
				}
			},
			exclude: ["zpp_nape"]
		};
		StructDefaultsMacro.applyDefaults(user, defaults);
	}

	function onDidChangeDisplayArguments(params:{arguments:Array<String>}) {
		displayArguments = params.arguments;
		onDidChange(DisplayArguments);
	}

	function onDidChangeDisplayServerConfig(config:DisplayServerConfig) {
		displayServer = config;
		onDidChange(DisplayServer);
	}
}
