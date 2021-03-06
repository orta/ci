import {CommonModule} from '@angular/common';
import {NgModule} from '@angular/core';
import {FormsModule} from '@angular/forms';
import {MatButtonModule, MatDialogModule, MatIconModule, MatSelectModule} from '@angular/material';

import {AddProjectDialogComponent} from './add-project-dialog.component';

@NgModule({
  declarations: [
    AddProjectDialogComponent,
  ],
  entryComponents: [
    AddProjectDialogComponent,
  ],
  imports: [
    /** Angular Library Imports */
    CommonModule, FormsModule,
    /** Internal Imports */
    /** Angular Material Imports */
    MatDialogModule, MatButtonModule, MatSelectModule, MatIconModule,
    /** Third-Party Module Imports */
  ],
})
export class AddProjectDialogModule {
}
