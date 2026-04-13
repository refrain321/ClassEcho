import urllib.request
import os

# 1. 获取当前脚本所在文件夹的绝对路径 (也就是你的 D:\ClassEcho)
current_dir = os.path.dirname(os.path.abspath(__file__))
# 2. 拼凑出完整的保存路径
save_path = os.path.join(current_dir, "test_audio.wav")

print("正在为你下载测试音频...")
# 这是一个开源的中文语音测试文件下载链接
url = "https://paddlespeech.bj.bcebos.com/PaddleAudio/zh.wav"
urllib.request.urlretrieve(url, save_path)
print(f"🎉 下载完成！文件已精确保存到: {save_path}")