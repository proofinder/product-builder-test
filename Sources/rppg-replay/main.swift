import Foundation
import RPPGCore

/// Offline POS runner.
///
///     swift run rppg-replay <input.csv> [output.csv] [--lambda1 0.99] [--lambda2 0.9]
///     swift run rppg-replay <input.csv> --compare <reference.csv>
///
/// `input.csv` is any file with `cR`, `cG`, `cB` columns — a recording exported from
/// the app, or `Tests/RPPGCoreTests/Fixtures/synthetic_C.csv`.
///
/// Two jobs:
///
/// * **replay** — recompute every POS intermediate from `C` alone and write them out.
///   Feeding a device recording back through this must reproduce the `rppg` column the
///   device wrote, bit for bit. That is the Stage 0 gate: if it does not hold, the
///   recording cannot be used to verify anything else.
/// * **compare** — diff this run against a reference CSV (MATLAB's `pos_reference.m`
///   output, or another recording) column by column and report the largest absolute
///   and relative difference. That is the Stage 5 gate.

struct Arguments {
    var inputPath: String
    var outputPath: String?
    var comparePath: String?
    var lambda1: Double = 0.99
    var lambda2: Double = 0.9

    static func parse(_ raw: [String]) throws -> Arguments {
        var positional: [String] = []
        var comparePath: String?
        var lambda1 = 0.99
        var lambda2 = 0.9

        var index = 0
        while index < raw.count {
            let argument = raw[index]
            switch argument {
            case "--compare":
                index += 1
                guard index < raw.count else { throw ReplayError.usage("--compare needs a path") }
                comparePath = raw[index]
            case "--lambda1":
                index += 1
                guard index < raw.count, let value = Double(raw[index]) else {
                    throw ReplayError.usage("--lambda1 needs a number")
                }
                lambda1 = value
            case "--lambda2":
                index += 1
                guard index < raw.count, let value = Double(raw[index]) else {
                    throw ReplayError.usage("--lambda2 needs a number")
                }
                lambda2 = value
            default:
                if argument.hasPrefix("--") { throw ReplayError.usage("unknown option \(argument)") }
                positional.append(argument)
            }
            index += 1
        }

        guard let inputPath = positional.first else {
            throw ReplayError.usage("no input CSV given")
        }
        return Arguments(
            inputPath: inputPath,
            outputPath: positional.count > 1 ? positional[1] : nil,
            comparePath: comparePath,
            lambda1: lambda1,
            lambda2: lambda2
        )
    }
}

enum ReplayError: Error, CustomStringConvertible {
    case usage(String)
    case io(String)

    var description: String {
        switch self {
        case .usage(let message):
            return """
            \(message)

            usage: rppg-replay <input.csv> [output.csv] [--compare reference.csv]
                               [--lambda1 0.99] [--lambda2 0.9]
            """
        case .io(let message):
            return message
        }
    }
}

/// Columns checked when comparing two runs, in the order the algorithm computes them —
/// so the first mismatch points at the earliest stage that diverged.
let comparableColumns = [
    "cMeanR", "cMeanG", "cMeanB",
    "cNormR", "cNormG", "cNormB",
    "s1", "s2", "sMean1", "sMean2",
    "sVar1", "sVar2", "sStd1", "sStd2",
    "h", "hMean", "rppg"
]

let comparableColumnsHeader = (["cR", "cG", "cB"] + comparableColumns).joined(separator: ",")

/// Left-pads a column name so the diff table lines up without `%s` formatting, which
/// is unreliable across Foundation implementations.
func padded(_ name: String, to width: Int) -> String {
    name.count >= width ? name : name + String(repeating: " ", count: width - name.count)
}

func columnValues(of step: POSProcessor.Step, named name: String) -> Double? {
    switch name {
    case "cMeanR": return step.cMean.red
    case "cMeanG": return step.cMean.green
    case "cMeanB": return step.cMean.blue
    case "cNormR": return step.cNormalized.red
    case "cNormG": return step.cNormalized.green
    case "cNormB": return step.cNormalized.blue
    case "s1": return step.s.first
    case "s2": return step.s.second
    case "sMean1": return step.sMean.first
    case "sMean2": return step.sMean.second
    case "sVar1": return step.sVar.first
    case "sVar2": return step.sVar.second
    case "sStd1": return step.sStd.first
    case "sStd2": return step.sStd.second
    case "h": return step.h
    case "hMean": return step.hMean
    case "rppg": return step.rppg
    default: return nil
    }
}

func run() throws {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))

    guard let text = try? String(contentsOfFile: arguments.inputPath, encoding: .utf8) else {
        throw ReplayError.io("cannot read \(arguments.inputPath)")
    }
    let samples = try SignalCSV.parseChannelTriples(text)
    guard !samples.isEmpty else { throw ReplayError.io("no usable cR/cG/cB rows in \(arguments.inputPath)") }

    let configuration = POSProcessor.Configuration(lambda1: arguments.lambda1, lambda2: arguments.lambda2)
    let steps = POSProcessor.run(samples, configuration: configuration)

    print("replayed \(steps.count) of \(samples.count) rows  (lambda1=\(arguments.lambda1), lambda2=\(arguments.lambda2))")
    if let last = steps.last {
        print(String(format: "final rppg = %.12g,  max |h| = %.6g",
                     last.rppg,
                     steps.reduce(0.0) { Swift.max($0, abs($1.h)) }))
    }

    if let outputPath = arguments.outputPath {
        var lines = [comparableColumnsHeader]
        lines.reserveCapacity(steps.count + 1)
        for step in steps {
            let fields = ["cR", "cG", "cB"].map { name -> String in
                switch name {
                case "cR": return SignalCSV.format(step.c.red)
                case "cG": return SignalCSV.format(step.c.green)
                default: return SignalCSV.format(step.c.blue)
                }
            } + comparableColumns.map { SignalCSV.format(columnValues(of: step, named: $0) ?? .nan) }
            lines.append(fields.joined(separator: ","))
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("wrote \(outputPath)")
    }

    if let comparePath = arguments.comparePath {
        guard let referenceText = try? String(contentsOfFile: comparePath, encoding: .utf8) else {
            throw ReplayError.io("cannot read \(comparePath)")
        }
        var worstColumn = ""
        var worstAbsolute = 0.0
        var worstRelative = 0.0
        var comparedColumns = 0

        for name in comparableColumns {
            guard let reference = try? SignalCSV.parseColumn(name, from: referenceText),
                  !reference.isEmpty else { continue }
            comparedColumns += 1
            let count = Swift.min(reference.count, steps.count)
            var maxAbsolute = 0.0
            var maxRelative = 0.0
            for index in 0..<count {
                guard let mine = columnValues(of: steps[index], named: name) else { continue }
                let theirs = reference[index]
                let absolute = abs(mine - theirs)
                maxAbsolute = Swift.max(maxAbsolute, absolute)
                let scale = Swift.max(abs(mine), abs(theirs))
                if scale > 0 { maxRelative = Swift.max(maxRelative, absolute / scale) }
            }
            print("  " + padded(name, to: 8)
                  + String(format: "max|diff| = %.3e   max rel = %.3e", maxAbsolute, maxRelative))
            if maxAbsolute > worstAbsolute {
                worstAbsolute = maxAbsolute
                worstRelative = maxRelative
                worstColumn = name
            }
        }

        guard comparedColumns > 0 else {
            throw ReplayError.io("\(comparePath) has none of the expected columns")
        }
        print("worst: " + (worstColumn.isEmpty ? "none" : worstColumn)
              + String(format: "  max|diff| = %.3e  (rel %.3e)", worstAbsolute, worstRelative))
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
