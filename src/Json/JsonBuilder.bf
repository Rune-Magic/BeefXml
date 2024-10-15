using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Json;

class JsonBuilder : this(StreamWriter stream, Options flags = .Format)
{
	public enum Options
	{
		None = 0,
		Format = 1,
	}

	public StringView IndentString { protected get; set; } = "    ";
	protected int indent = 0;

	private mixin WriteLine()
	{
		if (flags.HasFlag(.Format))
		{
			Try!(stream.WriteLine());
			for (int i < indent)
				Try!(stream.Write(IndentString));
		}
	}

	public Result<void> Write(JsonToken token)
	{
		switch (token)
		{
		case .True: Try!(stream.Write("true"));
		case .False: Try!(stream.Write("false"));
		case .Null: Try!(stream.Write("null"));
		case .Int(let val): Try!(stream.Write(val.ToString(..scope .())));
		case .Float(let val): Try!(stream.Write(val.ToString(..scope .())));
		case .String(let val): Try!(stream.Write(val.Quote(..scope .())));

		case .Colon: Try!(stream.Write(": "));
		case .Comma: Try!(stream.Write(", ")); WriteLine!();
		case .EOF: WriteLine!();

		case .LBracket:
			Try!(stream.Write("["));
			indent++;
			WriteLine!();
		case .RBracket:
			Try!(stream.Write("]"));
		case .LSquirly:
			Try!(stream.Write("{"));
			indent++;
			WriteLine!();
		case .RSquirly:
			Try!(stream.Write("}"));
		}

		return .Ok;
	}

	public Result<void> Write(JsonElement element)
	{
		switch (element)
		{
		case .Null: Try!(Write(JsonToken.Null));
		case .Int(let val): Try!(Write(JsonToken.Int(val)));
		case .Float(let val): Try!(Write(JsonToken.Float(val)));
		case .String(let val): Try!(Write(JsonToken.String(val)));
		case .Bool(let bool): Try!(Write(bool ? .True : .False));
		case .Object(let object):
			Try!(Write(.LSquirly));
			int i = 0;
			for (let kv in object)
			{
				Try!(Write(JsonToken.String(kv.key)));
				Try!(Write(.Colon));
				Try!(Write(kv.value));
				if (++i == object.Count)
				{
					indent--;
					WriteLine!();
					Try!(Write(.RSquirly));
					break;
				}

				Try!(Write(.Comma));
			}
		case .Array(let array):
			Try!(Write(.LBracket));
			for (let item in array)
			{
				Try!(Write(item));
				if (@item.Index + 1 == array.Count)
				{
					indent--;
					WriteLine!();
					Try!(Write(.RBracket));
					break;
				}
	
				Try!(Write(.Comma));
			}
		}

		return .Ok;
	}
}