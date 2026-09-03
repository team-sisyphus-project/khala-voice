import { ApiClient } from "@core/api";
import { Uploader } from "@core/upload";

/**
 * One instance app-wide.
 *
 * `Uploader` holds the upload queue, so multiple instances would try to
 * upload the same item concurrently and register duplicates.
 */
export const api = new ApiClient();
export const uploader = new Uploader(api);
