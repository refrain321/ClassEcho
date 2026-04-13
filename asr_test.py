import requests
import os

# ================= 配置区 =================
# 替换为你刚刚复制的真实 API Key，保留双引号！例如："sk-ab123456789"
API_KEY = "sk-jhppnayjorteqputhgxecvatrrdkoahroyzeuwykfqubhngo"  
# ==========================================

def speech_to_text():
    # 1. 精准定位：获取当前代码文件所在的目录，并拼凑出音频的绝对路径
    current_dir = os.path.dirname(os.path.abspath(__file__))
    audio_path = os.path.join(current_dir, "test_audio.wav")
    
    url = "https://api.siliconflow.cn/v1/audio/transcriptions"
    
    # 2. 检查文件是否存在
    if not os.path.exists(audio_path):
        print(f"❌ 错误：在 {current_dir} 下找不到 test_audio.wav")
        print("请确认音频文件是否和本代码在同一个文件夹！")
        return
        
    headers = {
        "Authorization": "Bearer " + API_KEY
    }

    print(f"找到音频文件：{audio_path}")
    print("🚀 开始发送音频到云端，请稍候...")
    
    # 3. 读取并发送音频文件
    with open(audio_path, "rb") as file:
        files = {
            "file": ("test_audio.wav", file, "audio/wav"),
        }
        data = {
            "model": "FunAudioLLM/SenseVoiceSmall", # 使用阿里开源的极速模型
            "language": "zh" # 设定语言为中文
        }
        
        response = requests.post(url, headers=headers, files=files, data=data)

    # 4. 处理返回结果
    if response.status_code == 200:
        result = response.json()
        print("\n🎉 识别成功！识别结果如下：")
        print("=" * 40)
        
        # 提取文本内容
        if "text" in result:
            print(result["text"])
        else:
            print("（未返回文本内容）")
            
        print("=" * 40)
    else:
        print("\n❌ 识别失败！")
        print("状态码:", response.status_code)
        print("错误信息:", response.text)

if __name__ == "__main__":
    speech_to_text()