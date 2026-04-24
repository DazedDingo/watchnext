import { GoogleGenerativeAI } from "@google/generative-ai";

/**
 * Thin wrapper over Gemini so call sites don't repeat SDK boilerplate and so
 * prompts + generation config stay consistent across scoreRecommendations,
 * rescoreRecommendations, and concierge. Free tier today is 1,500 req/day on
 * gemini-2.5-flash — comfortably above a two-person household's usage.
 *
 * Why Gemini (not Anthropic): zero incremental cost under the free tier for
 * typical household usage. Before this migration every refresh burned
 * ~$0.10-$0.20 of Claude tokens; the user flagged that as a non-obvious cost
 * on top of their claude.ai subscription.
 */

export const DEFAULT_GEMINI_MODEL = "gemini-2.5-flash";

export interface GeminiClient {
  /**
   * One-shot text completion. `systemInstruction` carries static prefix
   * (instructions + taste profile); `messages` are the variable turns. Output
   * is a single text string; parsing JSON is the caller's responsibility.
   */
  generate(params: {
    systemInstruction: string;
    messages: Array<{ role: "user" | "model"; text: string }>;
    maxOutputTokens?: number;
  }): Promise<string>;
}

/** Production client — hits the real Gemini API. */
export function makeGeminiClient(apiKey: string, model: string): GeminiClient {
  const sdk = new GoogleGenerativeAI(apiKey);
  return {
    async generate({ systemInstruction, messages, maxOutputTokens }) {
      const gen = sdk.getGenerativeModel({
        model,
        systemInstruction,
      });
      const contents = messages.map((m) => ({
        role: m.role,
        parts: [{ text: m.text }],
      }));
      const res = await gen.generateContent({
        contents,
        generationConfig: {
          maxOutputTokens: maxOutputTokens ?? 2048,
          temperature: 0.6,
        },
      });
      return res.response.text();
    },
  };
}
