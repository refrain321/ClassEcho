import requests
import os

# ================= 配置区 =================
API_KEY = "sk-jhppnayjorteqputhgxecvatrrdkoahroyzeuwykfqubhngo"  # 填入你的硅基流动 API Key
# ==========================================

def get_text_from_audio(audio_path):
    print("🎤 [1/2] 正在听录音，努力转写中...")
    url = "https://api.siliconflow.cn/v1/audio/transcriptions"
    headers = {"Authorization": "Bearer " + API_KEY}
    
    with open(audio_path, "rb") as file:
        files = {"file": ("test_audio.wav", file, "audio/wav")}
        data = {"model": "FunAudioLLM/SenseVoiceSmall", "language": "zh"}
        response = requests.post(url, headers=headers, files=files, data=data)
        
    if response.status_code == 200:
        return response.json().get("text", "")
    else:
        print("❌ 语音转写失败:", response.text)
        return None

def get_summary_from_text(text):
    print("🧠 [2/2] 正在思考，提炼课堂重点...")
    url = "https://api.siliconflow.cn/v1/chat/completions"
    headers = {
        "Authorization": "Bearer " + API_KEY,
        "Content-Type": "application/json"
    }
    payload = {
        "model": "deepseek-ai/DeepSeek-V3", 
        "messages": [
            {
                "role": "system", 
                "content": "你是一个硬核课堂总结助手。请精准提取老师讲课文本中的核心知识点，用清晰的列表输出，并标注'考点'。"
            },
            {"role": "user", "content": text}
        ]
    }
    response = requests.post(url, headers=headers, json=payload)
    
    if response.status_code == 200:
        return response.json()["choices"][0]["message"]["content"]
    else:
        print("❌ 大模型提炼失败:", response.text)
        return None

def main():
    # 获取音频路径
    current_dir = os.path.dirname(os.path.abspath(__file__))
    audio_path = os.path.join(current_dir, "test_audio.wav")
    
    if not os.path.exists(audio_path):
        print("❌ 找不到 test_audio.wav，请确认文件存在！")
        return

    # 步骤 1：录音转文字
    raw_text = get_text_from_audio(audio_path)
    if not raw_text:
        return
    print(f"   ✅ 听到原话：{raw_text}\n")
    
    # 步骤 2：文字生总结
    summary = get_summary_from_text(raw_text)
    if not summary:
        return
        
    print("✨ 最终课堂笔记 ✨")
    print("=" * 40)
    print(summary)
    print("=" * 40)

if __name__ == "__main__":
    main()