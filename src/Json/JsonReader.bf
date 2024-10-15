using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Json;

class JsonReader : this(MarkupSource source, Options flags = .None)
{
	public enum Options : uint8
	{
		None = 0,
		DisallowComments = 1,
		DisallowNull = 2,
	}

	BumpAllocator alloc = new .() ~ delete _;
	MarkupSource.Index startIdx = default;

	public void Error(StringView str, params Object[] args)
	{
		source.ErrorNoIndex(str, params args);
		source.[Friend]WriteIndex(startIdx, source.CurrentIdx.col - startIdx.col);
		Debug.Break();
	}

	public Result<JsonToken> NextToken()
	{
		source.ConsumeWhitespace();
		if (source.Ended) return .Ok(.EOF);
		startIdx = source.CurrentIdx;

		if (source.Consume('{')) return .Ok(.LSquirly);
		if (source.Consume('}')) return .Ok(.RSquirly);
		if (source.Consume('[')) return .Ok(.LBracket);
		if (source.Consume(']')) return .Ok(.RBracket);
		if (source.Consume(',')) return .Ok(.Comma);
		if (source.Consume(':')) return .Ok(.Colon);

		if (source.Consume('"'))
		{
			String str = scope .(32);
			while (true)
			{
				if (!source.PeekNext(let c, let length))
				{
					source.Error("Expected '\"'");
					return .Err;
				}
				source.MoveBy(length);
				if (c == '"') break;
				str.Append(c);
			}
			String outString = new:alloc .(str.Length);
			switch (str.Unescape(outString))
			{
			case .Ok:
				return .Ok(.String(outString));
			case .Err:
				Error("Something went wrong while unescaping string");
				return .Err;
			}
		}

		if (source.Consume("false")) return .Ok(.False);
		if (source.Consume("true")) return .Ok(.True);
		if (source.Consume("null"))
		{
			if (flags.HasFlag(.DisallowNull))
			{
				Error("null is not allowed");
				return .Err;
			}
			return .Ok(.Null);
		}

		if (source.Consume("//"))
		{
			if (flags.HasFlag(.DisallowComments))
			{
				Error("Comments are not allowed");
				return .Err;
			}
			while (!source.Consume('\n')) source.MoveBy(1);
		}

		if (source.Consume("/*"))
		{
			if (flags.HasFlag(.DisallowComments))
			{
				Error("Comments are not allowed");
				return .Err;
			}
			while (!source.Consume("*/")) source.MoveBy(1);
		}

		Debug.Assert(source.PeekNext(var c, var length));
		source.MoveBy(length);

		if (c.IsNumber)
		{
			String builder = scope .(16)..Append(c);
			while (true)
			{
				if (!source.PeekNext(out c, out length)) break;
				if (!c.IsLetterOrDigit && c != '.') break;
				source.MoveBy(length);
				builder.Append(c);
			}
			switch (int.Parse(builder))
			{
			case .Ok(let val):
				return .Ok(.Int(val));
			case .Err(let err):
				switch (double.Parse(builder))
				{
				case .Ok(let val):
					return .Ok(.Float(val));
				case .Err:
					source.Error($"Malformed number: {err}");
					return .Err;
				}
			}
		}

		source.Error($"Unexpected '{c}'");
		return .Err;
	}

	public Result<JsonElement> Parse()
	{
		switch (Try!(NextToken()))
		{
		case .True: return .Ok(true);
		case .False: return .Ok(false);
		case .Null: return .Ok(null);
		case .Int(let val): return .Ok(val);
		case .Float(let val): return .Ok(val);
		case .String(let val): return .Ok(val);
		case .EOF:
			source.Error("Expected element");
			return .Err;
		case .LSquirly:
			Dictionary<String, JsonElement> object = new:alloc .(4);
			loop: while (true)
			{
				String key;
				if (!(Try!(NextToken()) case .String(out key)))
				{
					Error("Expected string");
					return .Err;
				}

				if (!(Try!(NextToken()) case .Colon))
				{
					Error("Expected ':'");
					return .Err;
				}

				object.Add(key, Try!(Parse()));

				switch (Try!(NextToken()))
				{
				case .Comma:
				case .RSquirly:
					break loop;
				default:
					Error("Expected ',' or '}'");
					return .Err;
				}
			}
			return .Ok(.Object(object));
		case .LBracket:
			List<JsonElement> array = new:alloc .(4);
			loop: while (true)
			{
				array.Add(Try!(Parse()));
	
				switch (Try!(NextToken()))
				{
				case .Comma:
				case .RBracket:
					break loop;
				default:
					Error("Expected ',' or ']'");
					return .Err;
				}
			}
			return .Ok(.Array(array));
		case .Comma:
			Error("Unexpected ','");
			return .Err;
		case .Colon:
			Error("Unexpected ':'");
			return .Err;
		case .RBracket:
			Error("Unexpected ']'");
			return .Err;
		case .RSquirly:
			Error("Unexpected '}'");
			return .Err;
		}
	}
}