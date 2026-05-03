import Foundation
import julius
import zoomies

struct WeatherTool: Tool {
    let definition = ToolDefinition(
        name: "get_weather",
        description: "Get the current weather for a city",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object([
                    "type": .string("string"),
                    "description": .string("City name"),
                ]),
            ]),
            "required": .array([.string("city")]),
        ]),
    )

    func execute(_ call: ToolCall) async throws -> ToolResult {
        let city = extractCity(from: call.arguments)
        return ToolResult(callId: call.id, output: weather(for: city))
    }

    private func extractCity(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let city = json["city"] as? String
        else { return "" }
        return city.lowercased()
    }

    private func weather(for city: String) -> String {
        if city.contains("venice") || city.contains("venezia") {
            "24°C, sunny"
        } else if city.contains("paris") {
            "14°C, cloudy"
        } else if city.contains("hossegor") {
            "16°C, rainy af"
        } else {
            "I don't know, look at the window maybe?"
        }
    }
}
