interface Props {
  title: string;
  message: string;
  confirmLabel?: string;
  confirmVariant?: "danger" | "primary";
  onConfirm: () => void;
  onCancel: () => void;
}

export default function ConfirmDialog({
  title, message, confirmLabel = "Confirm", confirmVariant = "primary", onConfirm, onCancel,
}: Props) {
  const btnClass = confirmVariant === "danger"
    ? "bg-red-600 hover:bg-red-700 dark:bg-red-500"
    : "bg-blue-600 hover:bg-blue-700 dark:bg-blue-500";

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm">
      <div className="mx-4 w-full max-w-sm rounded-xl border border-gray-200 bg-white p-6 shadow-xl dark:border-gray-700 dark:bg-gray-900">
        <h3 className="mb-2 text-lg font-semibold">{title}</h3>
        <p className="mb-4 text-sm text-gray-500 dark:text-gray-400">{message}</p>
        <div className="flex justify-end gap-2">
          <button onClick={onCancel} className="rounded-lg border border-gray-300 px-4 py-2 text-sm hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800">
            Cancel
          </button>
          <button onClick={onConfirm} className={`rounded-lg px-4 py-2 text-sm font-medium text-white ${btnClass}`}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
