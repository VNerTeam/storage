# inbox

Upload file `.zip` chứa video vào thư mục này. Workflow **"Tải video lên release (video-storage)"**
sẽ tự giải nén, tải từng video lên release (`video-storage`, `video-storage-002`, ...) rồi xoá file zip.

- Chỉ nhận đuôi `.zip` (không mật khẩu). Mỗi zip tối đa 100 MB nếu push bằng git (25 MB nếu upload qua web).
- Zip lớn hơn: Actions → Run workflow → dán link https của zip vào ô `zip_url`.
- File khác (như README này) được bỏ qua.
