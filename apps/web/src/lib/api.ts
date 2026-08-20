import { ApiClient } from "@core/api";
import { Uploader } from "@core/upload";

/**
 * 앱 전역에서 하나만 쓴다.
 *
 * `Uploader` 가 업로드 큐를 들고 있어서 인스턴스가 여러 개면
 * 같은 항목을 동시에 올리려 들고 중복 등록이 난다.
 */
export const api = new ApiClient();
export const uploader = new Uploader(api);
